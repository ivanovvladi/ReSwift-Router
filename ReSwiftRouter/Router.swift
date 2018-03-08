//
//  Router.swift
//  Meet
//
//  Created by Benjamin Encz on 11/11/15.
//  Copyright © 2015 DigiTales. All rights reserved.
//

import Foundation
import ReSwift

open class Router<State: StateType>: StoreSubscriber {

    public typealias NavigationStateTransform = (Subscription<State>) -> Subscription<NavigationState>
    
    var store: Store<State>
    var lastNavigationState = NavigationState()
    var routables: [Routable] = []
    let waitForRoutingCompletionQueue = DispatchQueue(label: "WaitForRoutingCompletionQueue", attributes: [])
    
    public init(store: Store<State>, rootRoutable: Routable, stateTransform: @escaping NavigationStateTransform) {
        self.store = store
        self.routables.append(rootRoutable)
        self.store.subscribe(self, transform: stateTransform)
    }
    
    open func newState(state: NavigationState) {
        let actions = Router.routingActionsForTransitionFrom(lastNavigationState.route,
                                                             newRoute: state.route,
                                                             skipRoute: state.skipRoute,
                                                             routables: routables)
        let routingActions = actions.0
        routables = actions.1
        
        routingActions.forEach { routingAction in
            
            let semaphore = DispatchSemaphore(value: 0)
            
            // Dispatch all routing actions onto this dedicated queue. This will ensure that
            // only one routing action can run at any given time. This is important for using this
            // Router with UI frameworks. Whenever a navigation action is triggered, this queue will
            // block (using semaphore_wait) until it receives a callback from the Routable
            // indicating that the navigation action has completed
            waitForRoutingCompletionQueue.async {
                switch routingAction {
                    
                case let .pop(responsibleRoutableIndex, segmentToBePopped, segmentToBeSkipped):
                    DispatchQueue.main.async {
                        self.routables[responsibleRoutableIndex]
                            .popRouteSegment(
                                segmentToBePopped,
                                animated: state.changeRouteAnimated,
                                skipRoute: segmentToBeSkipped) {
                                    semaphore.signal()
                        }
                        self.routables.remove(at: responsibleRoutableIndex + 1)
                    }
                    
                case let .change(responsibleRoutableIndex, segmentToBeReplaced, newSegment):
                    DispatchQueue.main.async {
                        self.routables[responsibleRoutableIndex].changeRouteSegment(
                            segmentToBeReplaced,
                            to: newSegment,
                            animated: state.changeRouteAnimated) {
                                semaphore.signal()
                        }
                    }
                    
                case let .push(responsibleRoutableIndex, segmentToBePushed):
                    DispatchQueue.main.async {
                        self.routables.append(
                            self.routables[responsibleRoutableIndex]
                                .pushRouteSegment(
                                    segmentToBePushed,
                                    animated: state.changeRouteAnimated) {
                                        semaphore.signal()
                            }
                        )
                    }
                }
                
                let waitUntil = DispatchTime.now() + Double(Int64(3 * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)
                
                let result = semaphore.wait(timeout: waitUntil)
                
                if case .timedOut = result {
                    print("[ReSwiftRouter]: Router is stuck waiting for a" +
                        " completion handler to be called. Ensure that you have called the" +
                        " completion handler in each Routable element.")
                    print("Set a symbolic breakpoint for the `ReSwiftRouterStuck` symbol in order" +
                        " to halt the program when this happens")
                    ReSwiftRouterStuck()
                }
            }
            
        }
        
        lastNavigationState = state
    }
    
    // MARK: Route Transformation Logic
    static func largestCommonSubroute(_ oldRoute: Route, newRoute: Route) -> Int {
        var largestCommonSubroute = 0
        
        while largestCommonSubroute < newRoute.count &&
            largestCommonSubroute < oldRoute.count &&
            newRoute[largestCommonSubroute] == oldRoute[largestCommonSubroute] {
                largestCommonSubroute += 1
        }
        
        return largestCommonSubroute
    }
    
    // Maps Route index to Routable index. Routable index is offset by 1 because the root Routable
    // is not represented in the route, e.g.
    // route = ["tabBar"]
    // routables = [RootRoutable, TabBarRoutable]
    static func routableIndexForRouteSegment(_ segment: Int) -> Int {
        return segment + 1
    }
    
    static func routingActionsForTransitionFrom(_ oldRoute: Route,
                                                newRoute: Route,
                                                skipRoute: Route,
                                                routables: [Routable]) -> ([RoutingActions], [Routable]) {
        
        var routingActions: [RoutingActions] = []
        var newRoutables = routables
        
        // Find the last common subroute between two routes
        let commonSubroute = largestCommonSubroute(oldRoute, newRoute: newRoute)
        
        if commonSubroute == oldRoute.count && commonSubroute == newRoute.count {
            return ([], newRoutables)
        }
        
        // This is the 3. case:
        // "The new route has a different element after the commonSubroute, we need to replace
        //  the old route element with the new one"
        if oldRoute.count > commonSubroute && newRoute.count > commonSubroute {
            let changeAction = RoutingActions.change(
                responsibleRoutableIndex: routableIndexForRouteSegment(commonSubroute),
                segmentToBeReplaced: oldRoute[commonSubroute],
                newSegment: newRoute[commonSubroute])
            
            if newRoutables.count > routableIndexForRouteSegment(commonSubroute) {
                let newElement = newRoute[commonSubroute]
                if let newIndex = oldRoute.index(of: newElement) {
                    let oldRoutable = newRoutables[routableIndexForRouteSegment(commonSubroute)]
                    newRoutables[routableIndexForRouteSegment(commonSubroute)] = newRoutables[routableIndexForRouteSegment(newIndex)]
                    newRoutables[routableIndexForRouteSegment(newIndex)] = oldRoutable
                }
            }
            
            routingActions.append(changeAction)
        }
        
        // Keeps track which element of the routes we are working on
        // We start at the end of the old route
        var routeBuildingIndex = oldRoute.count - 1
        
        // This is the 1. case:
        // "The old route had an element after the commonSubroute and the new route does not
        //  we need to pop the route segment after the commonSubroute"
        while routeBuildingIndex > newRoute.count - 1 {
            let routeSegmentToPop = oldRoute[routeBuildingIndex]
            let segmentToSkip = skipRoute.first(where: { $0 == routeSegmentToPop })
            
            let popAction = RoutingActions.pop(
                responsibleRoutableIndex: routableIndexForRouteSegment(routeBuildingIndex - 1),
                segmentToBePopped: routeSegmentToPop,
                segmentToBeSkipped: segmentToSkip
            )
            
            routingActions.append(popAction)
            routeBuildingIndex -= 1
        }
        
        // Push remainder of elements in new Route that weren't in old Route, this covers
        // the 2. case:
        // "The old route had no element after the commonSubroute and the new route does,
        //  we need to push the route segment(s) after the commonSubroute"
        let newRouteIndex = newRoute.count - 1
        
        while routeBuildingIndex < newRouteIndex {
            let routeSegmentToPush = newRoute[routeBuildingIndex + 1]
            
            let pushAction = RoutingActions.push(
                responsibleRoutableIndex: routableIndexForRouteSegment(routeBuildingIndex),
                segmentToBePushed: routeSegmentToPush
            )
            
            routingActions.append(pushAction)
            routeBuildingIndex += 1
        }
        
        return (routingActions, newRoutables)
    }
}

func ReSwiftRouterStuck() {}

enum RoutingActions {
    case push(responsibleRoutableIndex: Int, segmentToBePushed: RouteElementIdentifier)
    case pop(responsibleRoutableIndex: Int, segmentToBePopped: RouteElementIdentifier, segmentToBeSkipped: RouteElementIdentifier?)
    case change(responsibleRoutableIndex: Int, segmentToBeReplaced: RouteElementIdentifier, newSegment: RouteElementIdentifier)
}
