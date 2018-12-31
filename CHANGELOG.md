# Change Log

## Known Issues (as of current release)

As of this time, the following issues are known and awaiting some kind of resolution:

* PlayMedia with "Video" media type restriction returns no results--I need to see if "Movie" works, in which case, I'll need to reconcile the various types vs media types. Perhaps this entry field should be a datalist?
* Emby detects some DLNA devices but doesn't control or update them unless the UPnP proxy is enabled on the network (e.g. Sonos); this is a local configuration issue combined with an Emby server requirement, not a plugin bug.

## Version 0.3 (development)

* Add Inventory action on server to force re-inventory without Luup reload;
* SmartMute's default will now figure out how to accomplish mute based on what the reported device capabilities are, with first priority given to ToggleMute/Mute/Unmute commands, followed by SetVolume, and last Pause/Unpause.
* Allow DLNA clients now that we can see them working and test them;
* Add a 60-second delay in transition from (server) active to idle, in case new media starts playing;
* Tweak service files for better Reactor interaction;
* Enforce limit on number of results returned by PlayMedia search (default 25).

## Version 0.2 (pre-release)

* Make functional PlayMedia action with search;
* Behave better when server is unreachable (retry less frequently);
* Smooth out SmartMute function.

## Version 0.1 (pre-release)

* Initial release