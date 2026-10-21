struct MainWindowErrorPresentation: Equatable {
    struct Detail: Equatable {
        let titleKey: String?
        let message: String
    }

    let titleKey: String
    let details: [Detail]

    init?(inputError: String?, persistenceError: String?) {
        switch (inputError, persistenceError) {
        case (nil, nil):
            return nil
        case (let inputError?, nil):
            titleKey = "media.importFailedTitle"
            details = [Detail(titleKey: nil, message: inputError)]
        case (nil, let persistenceError?):
            titleKey = "persistence.errorTitle"
            details = [Detail(titleKey: nil, message: persistenceError)]
        case (let inputError?, let persistenceError?):
            titleKey = "common.multipleErrorsTitle"
            details = [
                Detail(titleKey: "media.importFailedTitle", message: inputError),
                Detail(titleKey: "persistence.errorTitle", message: persistenceError)
            ]
        }
    }
}
