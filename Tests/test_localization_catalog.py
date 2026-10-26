import json
import plistlib
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
LOCALIZATION_APIS = (
    re.compile(r'(?:String\s*\(\s*localized|NSLocalizedString|LocalizedStringKey)\s*\(\s*"([^"]+)"'),
    re.compile(
        r'(?:Text|Label|Button|Menu|Section|Toggle|Picker|TextField|ProgressView|'
        r'LabeledContent|NavigationLink|DisclosureGroup|GroupBox|ContentUnavailableView)'
        r'\s*\(\s*"([^"]+)"'
    ),
    re.compile(r'\.(?:alert|confirmationDialog)\s*\(\s*"([^"]+)"'),
)


def localization_catalog(locale):
    path = ROOT / 'Sources' / 'Resources' / locale / 'Localizable.strings'
    output = subprocess.run(
        ['plutil', '-convert', 'json', '-o', '-', str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    catalog = json.loads(output)
    if not isinstance(catalog, dict):
        raise ValueError(f'Localization catalog must be a dictionary: {path}')
    return catalog


class LocalizationCatalogTests(unittest.TestCase):
    def test_application_supports_english_only(self):
        resource_root = ROOT / 'Sources' / 'Resources'
        localized_directories = {
            path.name for path in resource_root.glob('*.lproj')
        }
        project = (ROOT / 'Bomu.xcodeproj' / 'project.pbxproj').read_text(encoding='utf-8')

        self.assertEqual(localized_directories, {'en.lproj', 'zh-Hans.lproj'})
        self.assertIn('name = "en"; path = "Sources/Resources/en.lproj/Localizable.strings"', project)
        self.assertNotIn('Sources/Resources/zh-Hans.lproj/Localizable.strings', project)
        self.assertIn('developmentRegion = en;', project)
        self.assertIn('knownRegions = (en, Base)', project)

        with (ROOT / 'Config' / 'Info.plist').open('rb') as info_file:
            info = plistlib.load(info_file)
        self.assertEqual(info['CFBundleLocalizations'], ['en'])

    def test_chinese_catalog_is_ready_for_later_enablement(self):
        english = localization_catalog('en.lproj')
        simplified_chinese = localization_catalog('zh-Hans.lproj')
        self.assertEqual(set(english), set(simplified_chinese))

        format_specifier = re.compile(
            r'%(?:\d+\$)?[-+#0 ]*\d*(?:\.\d+)?'
            r'(?:hh|h|ll|l|z|t|j|q|L)?[diuoxXfFeEgGaAcCsSpn@]'
        )
        for key in sorted(english):
            self.assertEqual(
                format_specifier.findall(english[key]),
                format_specifier.findall(simplified_chinese[key]),
                f'Format placeholders differ for localization key {key}',
            )

    def test_static_source_keys_exist_in_each_locale(self):
        catalogs = {'en.lproj': localization_catalog('en.lproj')}
        referenced_keys = set()
        for source in (ROOT / 'Sources').rglob('*.swift'):
            contents = source.read_text(encoding='utf-8')
            for pattern in LOCALIZATION_APIS:
                for key in pattern.findall(contents):
                    if '\\(' not in key:
                        referenced_keys.add(key)

        for locale, catalog in catalogs.items():
            missing_keys = sorted(referenced_keys - set(catalog))
            self.assertEqual(missing_keys, [], f'{locale} is missing source keys')

    def test_formatted_library_messages_use_catalog_keys_and_matching_arguments(self):
        formatted_messages = {
            'library.continueAt': ['%@'],
            'library.scanProgress': ['%lld', '%lld'],
        }
        catalogs = {'en.lproj': localization_catalog('en.lproj')}
        source = '\n'.join(
            path.read_text(encoding='utf-8')
            for path in (ROOT / 'Sources').rglob('*.swift')
        )

        for key, expected_arguments in formatted_messages.items():
            self.assertIn(f'NSLocalizedString("{key}"', source)
            self.assertNotIn(f'Text("{key} \\(', source)
            for locale, catalog in catalogs.items():
                value = catalog[key]
                placeholders = re.findall(r'%lld|%@', value)
                self.assertEqual(
                    len(placeholders),
                    len(expected_arguments),
                    f'{locale} {key} has an unexpected number of format placeholders',
                )
                self.assertEqual(placeholders, expected_arguments, f'{locale} {key} has mismatched format arguments')


if __name__ == '__main__':
    unittest.main()
