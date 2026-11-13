import Foundation

/// 统一的网盘动作：列目录 + 取直链
protocol CloudDrive {
    var rootID: String { get }
    func list(dirID: String) async throws -> [CloudFile]
    func direct(_ file: CloudFile) async throws -> DirectLink
}

enum DriveState {
    case quark(shareID: String, stoken: String)
}

struct DriveContext {
    let platform: Platform
    let cookie: String
    let state: DriveState
}

func makeDrive(_ context: DriveContext) -> CloudDrive {
    switch context.state {
    case .quark(let shareID, let stoken):
        return QuarkDrive(platform: context.platform,
                          cookie: context.cookie,
                          shareID: shareID,
                          stoken: stoken)
    }
}

// MARK: - 夸克 / UC

struct QuarkDrive: CloudDrive {
    let platform: Platform
    let cookie: String
    let shareID: String
    let stoken: String

    var rootID: String { "0" }

    private var client: QuarkClient {
        QuarkClient(platform: platform, cookie: cookie)
    }

    func list(dirID: String) async throws -> [CloudFile] {
        try await client.list(shareID: shareID, stoken: stoken, pdirFid: dirID)
    }

    func direct(_ file: CloudFile) async throws -> DirectLink {
        try await client.direct(shareID: shareID, stoken: stoken, file: file)
    }
}
