import Adwaita
import CAdwShim
import CVte
import Foundation

/// Phone-sized shell: every pane takes the full width, panes sit in an
/// AdwCarousel. Two modes (the swipe/selection conflict over RDP, where a
/// finger is one mouse pointer):
///   focus    — carousel not interactive, the terminal owns every drag
///   overview — carousel swipeable (mouse drag), panes non-targetable,
///              a tap picks the page under it and returns to focus
@main
struct MobileCarouselApp: App {

    let app = AdwaitaApp(id: ProcessInfo.processInfo.environment["MOBILE_APP_ID"]
        ?? "com.manaflow.cmux.poc.mobile")

    @State private var overview = false
    @State private var paneCount = Int(ProcessInfo.processInfo.environment["MOBILE_PANES"] ?? "") ?? 3
    @State private var page = 0
    @State private var titles: [String] = []
    @State private var fontScale = Double(ProcessInfo.processInfo.environment["MOBILE_FONT_SCALE"] ?? "") ?? 0.8
    @State private var closeRequest = 0

    var scene: Scene {
        let width = Int(ProcessInfo.processInfo.environment["MOBILE_W"] ?? "") ?? 392
        let height = Int(ProcessInfo.processInfo.environment["MOBILE_H"] ?? "") ?? 844
        Window(id: "main") { _ in
            MobileShellWidget(
                overview: overview,
                paneCount: paneCount,
                fontScale: fontScale,
                closeRequest: closeRequest,
                onPageChanged: { index, count in
                    page = index
                    paneCount = count
                },
                onTitleChanged: { index, title in
                    var next = titles
                    while next.count <= index { next.append("") }
                    next[index] = title
                    titles = next
                },
                onExitOverview: { overview = false },
                onFontScale: { fontScale = $0 }
            )
            .topToolbar {
                HeaderBar {
                    Button(icon: .custom(name: overview ? "view-reveal-symbolic" : "view-grid-symbolic")) {
                        overview.toggle()
                    }
                    .tooltip(overview ? "Back to pane" : "Overview: swipe between panes")
                } end: {
                    Button(icon: .custom(name: "tab-new-symbolic")) {
                        paneCount += 1
                    }
                    .tooltip("New pane")
                    Button(icon: .custom(name: "window-close-symbolic")) {
                        closeRequest += 1
                    }
                    .tooltip("Close this pane")
                }
                .headerBarTitle {
                    WindowTitle(
                        subtitle: overview
                            ? (MobileShellRuntime.shared.variant == .tabview ? "tap a pane" : "swipe · tap to pick")
                            : "\(page + 1) / \(paneCount)",
                        title: page < titles.count && !titles[page].isEmpty
                            ? titles[page] : "Pane \(page + 1)"
                    )
                }
            }
        }
        .defaultSize(width: width, height: height)
    }
}
