import Foundation
import WidgetKit

struct BusWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: WidgetConfigurationData?
    let response: ArrivalsResponse?
    let updateFailed: Bool

    static var placeholder: BusWidgetEntry {
        let now = Date()
        return BusWidgetEntry(
            date: now,
            configuration: WidgetConfigurationData(
                stationId: "22001",
                stationName: "강남역",
                routeIds: ["100100341", "100100360"]
            ),
            response: ArrivalsResponse(
                station: ArrivalStation(stationId: "22001", name: "강남역"),
                updatedAt: now,
                fetchedAt: now,
                arrivals: [
                    RouteArrival(
                        routeId: "100100341",
                        routeName: "341",
                        predictions: [
                            ArrivalPrediction(
                                order: 1,
                                arrivalAt: now.addingTimeInterval(180),
                                remainingSeconds: 180,
                                remainingStops: 2,
                                vehicleStatus: .running
                            ),
                            ArrivalPrediction(
                                order: 2,
                                arrivalAt: now.addingTimeInterval(720),
                                remainingSeconds: 720,
                                remainingStops: 6,
                                vehicleStatus: .running
                            ),
                        ]
                    ),
                    RouteArrival(
                        routeId: "100100360",
                        routeName: "360",
                        predictions: [
                            ArrivalPrediction(
                                order: 1,
                                arrivalAt: now.addingTimeInterval(420),
                                remainingSeconds: 420,
                                remainingStops: 4,
                                vehicleStatus: .running
                            )
                        ]
                    ),
                ]
            ),
            updateFailed: false
        )
    }
}

