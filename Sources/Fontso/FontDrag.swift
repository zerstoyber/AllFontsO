import CoreTransferable
import UniformTypeIdentifiers

struct FontDragItem: Codable, Transferable, Hashable {
    var identities: [String]
    var listName: String = ""
    var outsideName: String = ""
    var outsideSource: String = ""
    var outsideURL: String = ""
    /// Set when a sidebar row itself is dragged, so rows of the same kind can be rearranged.
    var sidebarKind: String = ""
    var sidebarID: Int64 = 0

    init(
        identities: [String] = [],
        listName: String = "",
        outsideName: String = "",
        outsideSource: String = "",
        outsideURL: String = "",
        sidebarKind: String = "",
        sidebarID: Int64 = 0
    ) {
        self.identities = identities
        self.listName = listName
        self.outsideName = outsideName
        self.outsideSource = outsideSource
        self.outsideURL = outsideURL
        self.sidebarKind = sidebarKind
        self.sidebarID = sidebarID
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        identities = try box.decodeIfPresent([String].self, forKey: .identities) ?? []
        listName = try box.decodeIfPresent(String.self, forKey: .listName) ?? ""
        outsideName = try box.decodeIfPresent(String.self, forKey: .outsideName) ?? ""
        outsideSource = try box.decodeIfPresent(String.self, forKey: .outsideSource) ?? ""
        outsideURL = try box.decodeIfPresent(String.self, forKey: .outsideURL) ?? ""
        sidebarKind = try box.decodeIfPresent(String.self, forKey: .sidebarKind) ?? ""
        sidebarID = try box.decodeIfPresent(Int64.self, forKey: .sidebarID) ?? 0
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
