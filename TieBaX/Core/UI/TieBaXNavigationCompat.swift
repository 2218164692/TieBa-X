import SwiftUI

/// A type-erased bridge for the route array used by the iOS 16 navigation
/// stack. iOS 14 has no `navigationDestination(for:)`, so the compatibility
/// modifier below materializes the current route as a hidden `NavigationLink`.
/// The bridge deliberately exposes only the top route and a pop operation;
/// feature views remain the sole owners of their typed route arrays.
private final class TieBaLegacyNavigationContext {
    private let currentValue: () -> Any?
    private let popValue: () -> Void

    init<Route: Hashable>(path: Binding<[Route]>) {
        currentValue = {
            path.wrappedValue.last.map { $0 as Any }
        }
        popValue = {
            guard path.wrappedValue.isEmpty == false else { return }
            path.wrappedValue.removeLast()
        }
    }

    func route<Route: Hashable>(as type: Route.Type) -> Route? {
        currentValue() as? Route
    }

    func isActive<Route: Hashable>(for type: Route.Type) -> Bool {
        route(as: type) != nil
    }

    func pop<Route: Hashable>(ifActiveFor type: Route.Type) {
        guard isActive(for: type) else { return }
        popValue()
    }
}

private struct TieBaLegacyNavigationContextKey: EnvironmentKey {
    static let defaultValue: TieBaLegacyNavigationContext?
        = nil
}

private extension EnvironmentValues {
    var tieBaLegacyNavigationContext: TieBaLegacyNavigationContext? {
        get { self[TieBaLegacyNavigationContextKey.self] }
        set { self[TieBaLegacyNavigationContextKey.self] = newValue }
    }
}

/// Navigation wrappers used by TieBa-X. NavigationStack is unavailable on
/// iOS 14, while the app still needs one source tree for the GitHub Actions
/// build. On the legacy path NavigationView provides the same push/pop model;
/// typed route arrays are bridged to hidden NavigationLinks below.
struct TieBaNavigationStack<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

struct TieBaNavigationPathStack<Route: Hashable, Content: View>: View {
    @Binding private var path: [Route]
    private let content: () -> Content

    init(
        path: Binding<[Route]>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _path = path
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) {
                content()
            }
        } else {
            legacyNavigation
        }
    }

    private var legacyNavigation: some View {
        let context = TieBaLegacyNavigationContext(path: $path)
        return NavigationView {
            content()
                .environment(\.tieBaLegacyNavigationContext, context)
        }
        .navigationViewStyle(.stack)
    }
}

extension View {
    @ViewBuilder
    func tieBaNavigationDestination<Route: Hashable, Destination: View>(
        for route: Route.Type,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            navigationDestination(for: route, destination: destination)
        } else {
            background(TieBaLegacyRouteLink(
                routeType: route,
                destination: destination
            ))
        }
    }

    @ViewBuilder
    func tieBaNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            background(TieBaLegacyBooleanLink(
                isPresented: isPresented,
                destination: destination
            ))
        }
    }
}

private struct TieBaLegacyRouteLink<Route: Hashable, Destination: View>: View {
    @Environment(\.tieBaLegacyNavigationContext)
    private var context

    let routeType: Route.Type
    let destination: (Route) -> Destination

    private var isActive: Binding<Bool> {
        guard let context else { return .constant(false) }
        return Binding(
            get: { context.isActive(for: routeType) },
            set: { active in
                if active == false {
                    context.pop(ifActiveFor: routeType)
                }
            }
        )
    }

    private var destinationView: AnyView {
        guard let context,
              let route = context.route(as: routeType) else {
            return AnyView(EmptyView())
        }
        return AnyView(destination(route))
    }

    var body: some View {
        NavigationLink(
            destination: destinationView,
            isActive: isActive
        ) {
            EmptyView()
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct TieBaLegacyBooleanLink<Destination: View>: View {
    @Binding var isPresented: Bool
    let destination: () -> Destination

    var body: some View {
        NavigationLink(
            destination: AnyView(destination()),
            isActive: $isPresented
        ) {
            EmptyView()
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
