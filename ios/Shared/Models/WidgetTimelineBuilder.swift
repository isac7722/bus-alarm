import Foundation

enum WidgetTimelineBuilder {
    static func eventDates(response: ArrivalsResponse, now: Date, refreshDate: Date) -> [Date] {
        var dates: Set<Date> = [now]
        var minuteTick = now.addingTimeInterval(60)
        while minuteTick < refreshDate {
            dates.insert(minuteTick)
            minuteTick = minuteTick.addingTimeInterval(60)
        }
        let freshnessBoundaries: [TimeInterval] = [60, 180, 300]
        for offset in freshnessBoundaries {
            let boundary = response.updatedAt.addingTimeInterval(offset)
            if boundary > now, boundary < refreshDate { dates.insert(boundary) }
        }
        for arrival in response.arrivals {
            for prediction in arrival.predictions {
                guard let arrivalAt = prediction.arrivalAt, arrivalAt > now, arrivalAt < refreshDate else { continue }
                dates.insert(arrivalAt)
            }
        }
        return dates.sorted()
    }
}
