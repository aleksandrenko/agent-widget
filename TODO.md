# TODO

- [x] **Claude limit is missing**: the Claude quota doesn't show in the footer. Find out why and fix it.
- [x] **Calendar shows events that don't exist**: the panel shows an event that isn't in the calendar. Check whether it uses stale/cached data and whether new and changed events are checked at all.
- [x] **Calendar: only today's upcoming events**: the count should include only today's events that are still ahead; past ones aren't counted.
- [x] **Mobile: e2e and deployment**: add the mobile app's e2e tests and deployment (like the `e2e` and prod indicators in the footer).
- [x] **Explorer mode (UI tour)**
  - New "Explorer" item in the menu bar icon's menu.
  - New `?` icon in the header, between the pin and the `✕`.
  - Clicking it starts a mode where a bubble next to each element of the panel explains what it is.
  - Each bubble has Prev / Next (to the previous / next element) and an `✕` that ends the mode.
