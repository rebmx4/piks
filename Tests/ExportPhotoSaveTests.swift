import XCTest
import Foundation

final class ExportPhotoSaveTests: XCTestCase {
    func testRequestOnlyAcceptsAnOwnedExportIDFromAnAppPage() {
        let good: [String: Any] = ["token":"exp-test", "id":"uexport_exp-test"]
        XCTAssertNotNil(ExportPhotoRequest(good))
        XCTAssertNil(ExportPhotoRequest(["token":"exp-test","id":"u-song"]))
        XCTAssertNil(ExportPhotoRequest(["token":"../x","id":"uexport_../x"]))
        XCTAssertNil(ExportPhotoRequest(["token":String(repeating:"x",count:100),"id":"uexport_x"]))
        XCTAssertTrue(ExportPhotoRequest.allows(URL(string:"https://rynpro.ru/ryn-next/"), mainFrame:true))
        XCTAssertTrue(ExportPhotoRequest.allows(URL(string:"https://rynpro.ru/ryn/"), mainFrame:true))
        XCTAssertFalse(ExportPhotoRequest.allows(URL(string:"https://rynpro.ru/ryn-next/"), mainFrame:false))
        XCTAssertFalse(ExportPhotoRequest.allows(URL(string:"https://example.org/ryn/"), mainFrame:true))
        XCTAssertFalse(ExportPhotoRequest.allows(URL(string:"http://rynpro.ru/ryn/"), mainFrame:true))
        XCTAssertFalse(ExportPhotoRequest.allows(URL(string:"https://rynpro.ru/other/"), mainFrame:true))
    }

    func testConcurrentAndRepeatedRequestsSaveTheSameFileOnce() throws {
        let saver = ExportPhotoSave(), request = try XCTUnwrap(ExportPhotoRequest(["token":"exp-one","id":"uexport_exp-one"]))
        let file = URL(fileURLWithPath:"/tmp/owned-export.mp4")
        var writes=0, completed=0
        var finish: ((Bool,String?) -> Void)?
        let write: ExportPhotoSave.Writer = { url, done in
            XCTAssertEqual(url,file); writes += 1; finish=done
        }
        saver.save(request,resolve:{_ in file},write:write) {ok,_ in XCTAssertTrue(ok);completed += 1}
        saver.save(request,resolve:{_ in XCTFail("pending save resolved twice");return nil},write:write) {ok,_ in XCTAssertTrue(ok);completed += 1}
        XCTAssertEqual(writes,1);XCTAssertEqual(completed,0)
        finish?(true,nil)
        XCTAssertEqual(completed,2)
        saver.save(request,resolve:{_ in XCTFail("saved file was already released");return nil},write:write) {ok,_ in XCTAssertTrue(ok);completed += 1}
        XCTAssertEqual(writes,1);XCTAssertEqual(completed,3)
        finish?(true,nil)
        XCTAssertEqual(completed,3,"late duplicate completion must be ignored")
    }

    func testFailureCanBeRetriedButNeverReportedAsSaved() throws {
        let saver=ExportPhotoSave(),request=try XCTUnwrap(ExportPhotoRequest(["token":"exp-retry","id":"uexport_exp-retry"]))
        let file=URL(fileURLWithPath:"/tmp/owned-export.mp4")
        var writes=0,results:[Bool]=[]
        let write: ExportPhotoSave.Writer = {_,done in writes += 1;done(writes>1,writes==1 ? "no permission":nil)}
        saver.save(request,resolve:{_ in file},write:write) {ok,error in results.append(ok);XCTAssertEqual(error,"no permission")}
        saver.save(request,resolve:{_ in file},write:write) {ok,_ in results.append(ok)}
        XCTAssertEqual(results,[false,true]);XCTAssertEqual(writes,2)
    }

    func testMissingOwnedFileDoesNotReachPhotos() throws {
        let saver=ExportPhotoSave(),request=try XCTUnwrap(ExportPhotoRequest(["token":"exp-missing","id":"uexport_exp-missing"]))
        saver.save(request,resolve:{_ in nil},write:{_,_ in XCTFail("must not save an unowned file")}) {ok,error in
            XCTAssertFalse(ok);XCTAssertNotNil(error)
        }
    }
}
