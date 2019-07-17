# Change Log

## Version 1.4 (development)

* Enhancement: Add `Wakeup` action for sessions to force session to appear action for a short period (optional `duration` parameter for time in seconds, default 60). It is recommended this be used by scenes configuring home theaters, etc. when it's likely that an otherwise-idle Emby session is about to be used. By forcing the session awake, the plugin will more quickly respond to first changes in play state (active sessions are updated every 5 seconds by default rather than every 60 seconds, so waking the session up puts on 5-second updates).

## Version 1.3 (released)

* Enhancement/workaround: Emby clients may not present the same UUID. In particular, the web browsers will often present a new UUID after clearing browser caches, etc. This can result in a proliferation of client devices on Vera, as each new UUID is handled as a new client. Work around this by filtering out those clients using the new `FilterClients` and `FilterDeviceNames` state variables, which may contain a list of Lua patterns to match against the Client string or Device Name, respectively. By default, client "Emby Mobile" is now filtered out, elimination Chrome/Firefox/etc. from default display. If the user wishes to see these clients, the filter variables may be adjusted accordingly.

## Version 1.2 (released)

* Add action BookmarkMedia, which allows the user to bookmark the current playing media/position (parameter "Bookmark" is the name used to save). Bookmarks are global to the server, so bookmarks can be resumed (using ResumeMedia) on any session (i.e. you can bookmark a movie on your phone and continue watching from that spot on your TV).
* Add "Bookmark" parameter to ResumeMedia action, to allow user to resume from a position previously bookmarked by BookmarkMedia.

## Version 1.1 (released)

* Code cleanup and fix a number of small bugs.

## Version 1.0 (released; first general release)

* Add "Sessions" tab on server control panel for controlling server and session visibility settings.
* Add "ResumeMedia" action to restart play of last media item after a stop. Note that this DOES NOT resume any following items that may have been in the queue. Emby has no persistent queue or anonymous playlist that can be resumed.
* Add "ViewMedia" action for session to force media browsing to the specified media id. Note that currently, while the API requires ID, name (title) and media type (at least, according to swagger), only media id (alone) seems to work, and the other parameters do nothing and/or can be omitted.
* Add HideOffline and HideIdle to hide offline or idle devices automatically. Set value to 1 to enable this feature.
* Make inventory query use ActiveWithinSeconds parameter as well, so list is more consistent with updates and fewer "Offline" devices are reported (e.g. aged-out devices that the user hasn't removed from the device list on the server).

## Version 0.3 (development release 2018-12-31)

* Change list of media types to better match capabilities in PlayMedia action;
* Add Inventory action on server to force re-inventory without Luup reload;
* SmartMute's default will now figure out how to accomplish mute based on what the reported device capabilities are, with first priority given to ToggleMute/Mute/Unmute commands, followed by SetVolume, and last Pause/Unpause.
* Allow DLNA clients now that we can see them working (not all are responsive--many require a UPnP proxy to be functional);
* Add a 60-second delay in transition from (server) active to idle, in case new media starts playing (so frequent polling continues for a short while after all clients go idle, in case a client starts playing again);
* Tweak service files for better Reactor interaction;
* Enforce limit on number of results returned by PlayMedia search (default 25).

## Version 0.2 (pre-release)

* Make functional PlayMedia action with search;
* Behave better when server is unreachable (retry less frequently);
* Smooth out SmartMute function.

## Version 0.1 (pre-release)

* Initial development release