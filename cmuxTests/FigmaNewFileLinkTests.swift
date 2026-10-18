import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct FigmaNewFileLinkTests {
    @Test(arguments: FigmaNewFileLink.Kind.allCases)
    func folderScoped(kind: FigmaNewFileLink.Kind) {
        let folder = "https://www.figma.com/files/team/764866853003674551/folder/643299150"
        #expect(FigmaNewFileLink.address(kind: kind, folder: folder)?.absoluteString == "https://www.figma.com/\(kind.rawValue)/new?folder_id=643299150&team_id=764866853003674551")
    }
    @Test(arguments: [nil, "", "garbage", "https://www.figma.com/files/folder/123", "https://evil.com/files/team/1/folder/2"] as [String?])
    func refusesMissingOrInvalidFolder(folder: String?) {
        for kind in FigmaNewFileLink.Kind.allCases {
            #expect(FigmaNewFileLink.address(kind: kind, folder: folder) == nil)
        }
    }
}
