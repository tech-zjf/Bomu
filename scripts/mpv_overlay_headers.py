"""Prepare public headers for the fixed mpv overlay, from verified source archives.

No dependency binary is rebuilt here. config.h/jconfig.h reflect the locked
runtime features recorded in Tools/MPVOverlay/inputs.json and upstream recipes.
All generated headers and pkg-config metadata remain in the isolated build root.
"""
from pathlib import Path
import re
import shutil


def prepare_headers(output, sources, libraries, library_names, configuration):
    ROOT = Path(output)
    PREFIX = ROOT / 'sysroot'
    INC = PREFIX / 'include'
    LIB = PREFIX / 'lib'
    PC = LIB / 'pkgconfig'
    for p in [INC, LIB, PC]: p.mkdir(parents=True, exist_ok=True)

    def copy(src, dst):
        dst = INC / dst
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    def pc(name, version, library, includes='', variables=''):
        (PC / (name+'.pc')).write_text(
            f'prefix={PREFIX}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\n'
            + variables + f'\nName: {name}\nDescription: Locked source headers and runtime\nVersion: {version}\n'
            + f'Libs: -L"${{libdir}}" -l{library}\nCflags: -I"${{includedir}}"{includes}\n')

    for name in library_names:
        dest = LIB / name
        if not dest.exists(): dest.symlink_to(libraries / name)
        stem = name.split('.')[0]
        alias = LIB / (stem + '.dylib')
        if not alias.exists(): alias.symlink_to(name)

    ff = sources['ffmpeg']
    for name in ['libavcodec','libavfilter','libavformat','libavutil','libavdevice','libswresample','libswscale']:
        for h in (ff/name).glob('*.h'): copy(h, Path(name)/h.name)
        versions = ''.join(p.read_text() for p in (ff/name).glob('version*.h'))
        tag = name.upper()
        version = '.'.join(re.search(r'#define\s+'+tag+'_VERSION_'+part+r'\s+(\d+)', versions)[1] for part in ['MAJOR','MINOR','MICRO'])
        pc(name,version,name[3:])

    ass = sources['libass']/'libass'
    for name in ['ass.h','ass_types.h']: copy(ass/name, 'ass/'+name)
    pc('libass','0.17.5','ass')

    pl = sources['libplacebo']/'src/include/libplacebo'
    shutil.copytree(pl,INC/'libplacebo',dirs_exist_ok=True)
    features = configuration['libplacebo']
    config = (pl/'config.h.in').read_text()
    config = config.replace('@majorver@', str(features['major']))
    config = config.replace('@apiver@', str(features['api']))
    definitions = [f'#define PL_HAVE_{name} 1' for name in features['enabled']]
    definitions += [f'#undef PL_HAVE_{name}' for name in features['disabled']]
    config = config.replace('@extra_defs@', '\n'.join(definitions))
    if re.search(r'@\w+@', config):
        raise ValueError('Unresolved libplacebo header template')
    (INC/'libplacebo/config.h').write_text(config)
    pc('libplacebo', features['version'], 'placebo', variables=
       f"pl_has_vulkan={int('VULKAN' in features['enabled'])}\n"
       f"pl_has_opengl={int('OPENGL' in features['enabled'])}\n")

    for h in ['archive.h','archive_entry.h']: copy(sources['libarchive']/'libarchive'/h,h)
    pc('libarchive','3.8.8','archive')
    bd = sources['libbluray']/'src'
    for name in ['libbluray/bluray.h','libbluray/keys.h','libbluray/bdnav/meta_data.h','libbluray/decoders/overlay.h','util/log_control.h']:
        copy(bd/name,'libbluray/'+Path(name).name)
    config=(bd/'libbluray/bluray-version.h.in').read_text()
    for k,v in [('MAJOR','1'),('MINOR','4'),('MICRO','1')]: config=config.replace('@BLURAY_VERSION_'+k+'@',v)
    (INC/'libbluray/bluray-version.h').write_text(config)
    pc('libbluray','1.4.1','bluray')
    copy(sources['lcms2']/'include/lcms2.h','lcms2.h')
    copy(sources['lcms2']/'include/lcms2_plugin.h','lcms2_plugin.h')
    pc('lcms2','2.19','lcms2')
    lua=sources['luajit']/'src'
    for h in ['lua.h','luaconf.h','lualib.h','lauxlib.h']: copy(lua/h,'luajit-2.1/'+h)
    pc('luajit','2.1.0','luajit-5', includes=' -I"${includedir}/luajit-2.1"')
    # libluajit-5.1.2.dylib has a compound ABI name; use the exact unversioned linker alias.
    alias=LIB/'libluajit-5.dylib'
    if not alias.exists(): alias.symlink_to('libluajit-5.1.2.dylib')
    copy(sources['mujs']/'mujs.h','mujs.h')
    pc('mujs','1.3.9','mujs')
    for h in (sources['rubberband']/'rubberband').glob('*.h'): copy(h,'rubberband/'+h.name)
    pc('rubberband','4.0.0','rubberband')
    copy(sources['uchardet']/'src/uchardet.h','uchardet/uchardet.h')
    pc('uchardet','0.0.8','uchardet',includes=' -I"${includedir}/uchardet"')
    copy(sources['zimg']/'src/zimg/api/zimg.h','zimg.h')
    pc('zimg','3.0.6','zimg')
    jpeg=sources['jpeg-turbo']/'src'
    for h in ['jpeglib.h','jmorecfg.h']: copy(jpeg/h,h)
    config=(jpeg/'jconfig.h.in').read_text()
    features = configuration['jpeg']
    for key, value in [('JPEG_LIB_VERSION', features['api']),
                       ('VERSION', features['version']),
                       ('LIBJPEG_TURBO_VERSION_NUMBER', features['versionNumber'])]:
        config = config.replace('@'+key+'@', str(value))
    for key, enabled in [('C_ARITH_CODING_SUPPORTED', features['arithmeticCoding']),
                         ('D_ARITH_CODING_SUPPORTED', features['arithmeticCoding']),
                         ('WITH_SIMD', features['simd'])]:
        definition = f'#define {key} 1' if enabled else f'/* #undef {key} */'
        config = config.replace('#cmakedefine '+key+' 1', definition)
    config=config.replace('#cmakedefine RIGHT_SHIFT_IS_UNSIGNED 1','/* #undef RIGHT_SHIFT_IS_UNSIGNED */')
    if re.search(r'@\w+@', config) or '#cmakedefine' in config:
        raise ValueError('Unresolved libjpeg header template')
    (INC/'jconfig.h').write_text(config)
    pc('libjpeg', features['version'], 'jpeg')
    return PREFIX
