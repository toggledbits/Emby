# Change Log

This project is in beta pending initial release. The current version is 0.3develop-181231. Please see the README for details and documentation.

## Known Issues (as of current release)

As of this time, the following issues are known and awaiting some kind of resolution:

* Emby detects some DLNA devices but doesn't control or update them unless the UPnP proxy is enabled on the network (e.g. Sonos); this is a local configuration issue combined with an Emby server requirement, not a plugin bug.
* I've decided not to do a media browser, at least for the moment. This plugin is intended for control and automation; it is not intended to be a UI replacement for any client, or an alternate user interface to those Emby clients provide.

## Version 0.4 (development)

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