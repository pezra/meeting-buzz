# MeetingBuzz

MeetingBuzz vibrates the phone shortly before any calendar event that involves another person, and it keeps vibrating until the alarm is dismissed.

## What gets a buzz

An event gets a buzz if someone other than you is on its attendee list. Conference rooms and projectors are not people, as far as MeetingBuzz is concerned. All-day events, canceled events and events you have declined are skipped. This does mean that a meeting you put on your calendar without inviting anyone will not buzz, even if you fully intend to show up and talk to a human.

Events that start at the same time share one alarm, titled something like "Review + 1 more starts in 30 seconds".

## Updates

MeetingBuzz updates when you open it, when the calendar changes while it is running, and whenever iOS grants it a background refresh or an overnight task. iOS decides when those last two happen, so “overnight” is more of an aspiration than a schedule.

The one trigger you control is Shortcuts. The app provides a **Refresh MeetingBuzz** action, and i recommend a personal automation that runs it a few times a day. The bottom of the buzz list shows how long ago the last background update happened and what triggered it.

## Building

You need Xcode 26 and an iPhone running iOS 26.1 or later. Open `MeetingBuzz.xcodeproj`, set the signing team to your own, change the bundle ID (`org.barelyenough.MeetingBuzz` is taken) and run it on your phone. Once it's installed, grant calendar and alarm access.

## License

BSD 3-Clause. See `LICENSE`.
