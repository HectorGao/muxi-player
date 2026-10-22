import Foundation
import Testing
@testable import MuxiCore

struct LibraryFilterTests {
    private func fixture() throws -> [MediaItem] {
        try JSONDecoder().decode([MediaItem].self, from: Data("""
        [
          {"Id":"a","Name":"Film 2","ProductionYear":2020,"Genres":["剧情"],"ProductionLocations":["中国","法国"],"CommunityRating":8.5,"DateCreated":"2026-10-01T00:00:00Z","UserData":{"Played":true}},
          {"Id":"b","Name":"Film 10","OriginalTitle":"Ocean","ProductionYear":2024,"Genres":["动画"],"ProductionLocations":["日本"],"CommunityRating":9,"DateCreated":"2026-10-02T00:00:00Z"},
          {"Id":"c","Name":"Film 1"}
        ]
        """.utf8))
    }

    @Test func combinedFiltersAndUnknownMetadata() throws {
        let items = try fixture()
        var filter = LibraryFilter()
        filter.year = 2020; filter.genre = "剧情"; filter.country = "法国"; filter.played = true
        #expect(filter.apply(to: items).map(\.id) == ["a"])
        filter.country = "中国"
        #expect(filter.apply(to: items).count == 1)
        filter.year = 2024
        #expect(filter.apply(to: items).isEmpty)
        filter = LibraryFilter(); filter.country = ""
        #expect(filter.apply(to: items).map(\.id) == ["c"])
        filter.country = nil; filter.played = false
        #expect(filter.apply(to: items).map(\.id) == ["b", "c"])
        #expect(filter.apply(to: items, search: "ocean").map(\.id) == ["b"])
    }

    @Test func sortingKeepsUnknownsLastAndUsesNaturalNames() throws {
        let items = try fixture()
        let cases: [(LibrarySort, [String])] = [(.added, ["b", "a", "c"]), (.newest, ["b", "a", "c"]),
                                               (.oldest, ["a", "b", "c"]), (.rating, ["b", "a", "c"]), (.name, ["c", "a", "b"])]
        for (sort, ids) in cases {
            var filter = LibraryFilter(); filter.sort = sort
            #expect(filter.apply(to: items).map(\.id) == ids)
        }
    }
}
