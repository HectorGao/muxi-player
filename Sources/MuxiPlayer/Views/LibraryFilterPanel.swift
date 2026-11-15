import SwiftUI
import MuxiCore

struct LibraryFilterPanel: View {
    @Bindable var library: LibraryStore
    let index: [MediaItem]
    @ViewState private var countriesOpen = false
    @ViewState private var genresOpen = false
    @ViewState private var yearText = ""
    private var genres: [String] {
        let values = Set(index.flatMap { $0.Genres ?? [] }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let preferred = ["剧情", "喜剧", "动作", "科幻", "动画", "爱情", "Drama", "Comedy", "Action", "Science Fiction", "Animation", "Romance"].filter { values.contains($0) }
        return preferred + values.subtracting(preferred).sorted()
    }
    private var countries: [String] { Array(Set(index.flatMap { $0.ProductionLocations ?? [] }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted { countryName($0) < countryName($1) } }
    private static let countryLabels: [String: String] = {
        let english = Locale(identifier: "en_US"), chinese = Locale(identifier: "zh_CN")
        var labels: [String: String] = ["": "未标注", "usa": "美国", "uk": "英国", "mainland china": "中国大陆"]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard let name = chinese.localizedString(forRegionCode: code) else { continue }
            labels[code.lowercased()] = name
            if let original = english.localizedString(forRegionCode: code) { labels[original.lowercased()] = name }
        }
        return labels
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilterOptionsRow(title: "内容", selected: $library.filter.kind, options: [("电影", "Movie"), ("剧集", "Series"), ("合集", "BoxSet")])
            FilterOptionsRow(title: "分辨率", selected: $library.filter.resolution, options: LibraryResolution.allCases.map { ($0.rawValue, $0) })
            FilterOptionsRow(title: "画面", selected: $library.filter.videoRange, options: LibraryVideoRange.allCases.map { ($0.rawValue, $0) })
            FilterOptionsRow(title: "音频", selected: $library.filter.audio, options: LibraryAudio.allCases.map { ($0.rawValue, $0) })
            HStack(alignment: .top, spacing: 14) {
                title("地区")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        FilterOptionButton(text: "全部", selected: library.filter.region == nil && library.filter.country == nil) {
                            library.filter.region = nil; library.filter.country = nil
                        }
                        ForEach(LibraryRegion.allCases, id: \.self) { region in
                            FilterOptionButton(text: region.rawValue, selected: library.filter.region == region) {
                                library.filter.country = nil; library.filter.region = region
                            }
                        }
                        FilterOptionButton(text: library.filter.country.map(countryName) ?? "更多国家…", selected: library.filter.country != nil) { countriesOpen = true }
                            .popover(isPresented: $countriesOpen) {
                                SearchableFilterList(title: "选择国家或地区", values: countries + [""], selected: library.filter.country, label: countryName) { value in
                                    library.filter.region = nil; library.filter.country = value; countriesOpen = false
                                }
                            }
                    }
                }.scrollIndicators(.hidden)
            }
            HStack(alignment: .top, spacing: 14) {
                title("年代")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        FilterOptionButton(text: "全部", selected: library.filter.decade == nil && library.filter.year == nil) {
                            library.filter.decade = nil; library.filter.year = nil
                        }
                        ForEach(Array(stride(from: Calendar.current.component(.year, from: Date()) / 10 * 10, through: 1980, by: -10)) + [-1], id: \.self) { decade in
                            FilterOptionButton(text: decade == -1 ? "1980年前" : "\(String(decade))年代", selected: library.filter.decade == decade) {
                                library.filter.year = nil; library.filter.decade = decade
                            }
                        }
                        TextField("指定年份", text: $yearText).textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel("指定年份")
                            .onChange(of: yearText) { _, text in
                                let digits = String(text.filter(\.isNumber).prefix(4))
                                if digits != text { yearText = digits }
                                if digits.isEmpty { library.filter.year = nil }
                                else if digits.count == 4, let year = Int(digits), year > 1800 {
                                    library.filter.decade = nil; library.filter.year = year
                                }
                            }
                            .onChange(of: library.filter.year) { _, year in yearText = year.map(String.init) ?? "" }
                            .onAppear { yearText = library.filter.year.map(String.init) ?? "" }
                    }
                }.scrollIndicators(.hidden)
            }
            HStack(alignment: .top, spacing: 14) {
                title("类型")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        FilterOptionButton(text: "全部", selected: library.filter.genre == nil) { library.filter.genre = nil }
                        ForEach(Array(genres.prefix(6)), id: \.self) { genre in
                            FilterOptionButton(text: genre, selected: library.filter.genre == genre) { library.filter.genre = genre }
                        }
                        FilterOptionButton(text: library.filter.genre.flatMap { genres.prefix(6).contains($0) ? nil : $0 } ?? "更多…",
                                           selected: library.filter.genre.map { !genres.prefix(6).contains($0) } ?? false) { genresOpen = true }
                            .popover(isPresented: $genresOpen) {
                                SearchableFilterList(title: "选择类型", values: genres, selected: library.filter.genre, label: { $0 }) { value in
                                    library.filter.genre = value; genresOpen = false
                                }
                            }
                    }
                }.scrollIndicators(.hidden)
            }
            FilterOptionsRow(title: "观看", selected: $library.filter.played, options: [("未观看", false), ("已观看", true)])
        }
    }

    private func title(_ value: String) -> some View { Text(value).font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .leading).padding(.top, 6) }

    private func countryName(_ value: String) -> String {
        Self.countryLabels[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? value
    }
}

private struct FilterOptionButton: View {
    let text: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.callout).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(selected ? Theme.accent : Color.primary)
                .background(selected ? Theme.accent.opacity(0.15) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FilterOptionsRow<Value: Hashable>: View {
    let title: String
    @Binding var selected: Value?
    let options: [(String, Value)]
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .leading).padding(.top, 6)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    FilterOptionButton(text: "全部", selected: selected == nil) { selected = nil }
                    ForEach(options.indices, id: \.self) { index in
                        FilterOptionButton(text: options[index].0, selected: selected == options[index].1) { selected = options[index].1 }
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
}

private struct SearchableFilterList: View {
    let title: String
    let values: [String]
    let selected: String?
    let label: (String) -> String
    let choose: (String?) -> Void
    @ViewState private var search = ""
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("搜索名称", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    entry("全部", value: nil)
                    ForEach(values.filter { search.isEmpty || $0.localizedStandardContains(search) || label($0).localizedStandardContains(search) }, id: \.self) { value in
                        entry(label(value), value: value)
                    }
                }
            }.frame(height: 280)
        }.padding(18).frame(width: 320).task { searchFocused = true }
    }
    private func entry(_ name: String, value: String?) -> some View {
        Button { choose(value) } label: {
            HStack { Text(name); Spacer(); if selected == value { Image(systemName: "checkmark").foregroundStyle(Theme.accent) } }
                .padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
