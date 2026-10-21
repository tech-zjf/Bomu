import XCTest

final class MainWindowErrorPresentationTests: XCTestCase {
    func testNoErrorsProduceNoAlert() {
        XCTAssertNil(MainWindowErrorPresentation(inputError: nil, persistenceError: nil))
    }

    func testSingleErrorKeepsItsSpecificTitleAndMessage() throws {
        let input = try XCTUnwrap(
            MainWindowErrorPresentation(inputError: "Import failed", persistenceError: nil)
        )
        XCTAssertEqual(input.titleKey, "media.importFailedTitle")
        XCTAssertEqual(input.details, [
            .init(titleKey: nil, message: "Import failed")
        ])

        let persistence = try XCTUnwrap(
            MainWindowErrorPresentation(inputError: nil, persistenceError: "Save failed")
        )
        XCTAssertEqual(persistence.titleKey, "persistence.errorTitle")
        XCTAssertEqual(persistence.details, [
            .init(titleKey: nil, message: "Save failed")
        ])
    }

    func testConcurrentErrorsAreBothPresentedWithTheirOwnContext() throws {
        let presentation = try XCTUnwrap(
            MainWindowErrorPresentation(inputError: "Import failed", persistenceError: "Save failed")
        )

        XCTAssertEqual(presentation.titleKey, "common.multipleErrorsTitle")
        XCTAssertEqual(presentation.details, [
            .init(titleKey: "media.importFailedTitle", message: "Import failed"),
            .init(titleKey: "persistence.errorTitle", message: "Save failed")
        ])
    }
}
