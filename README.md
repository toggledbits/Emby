# Emby
An Emby Interface for Vera Home Automation Controllers (Vera plugin).

The Emby Plugin is the interface for all Emby servers discovered in the network (servers outside the LAN can also be registered by IP discovery). The plugin has two types of child devices: servers and sessions. A server represents an Emby Server (you can have more than one). A session represents a connection from an Emby client to a server.

## Installation and Start-up

(this section needs work)

The plugin is currently available only from Github. Install by uploading to your Vera, then creating the base Emby Plugin master device (device file D_Emby1.xml and implementation file I_Emby1.xml).

Discovery is used to register the server; launch discovery from the plugin device's control panel. Once a server is registered, go into its control panel and use the login functionto get the necessary authentication token the plugin needs to access the server.

## Caveats

First and foremost, keep in mind that this plugin is to be used as an automation interface to Emby, and not as a replacement UI for clients. It's meant to do things like mute your player when the doorbell rings, or start playing music when you run a scene, for example. Although the plugin displays activity information for known clients as reported by the Emby server, it is neither possible nor practical for that information to be up-to-the-second accurate and identical to that displayed on the client itself. In fact, when an idle client begins playing media, it may take up to a minute before the plugin first reflects this state change and starts updating more frequently.

Emby clients are not required to implement every action, and many don't. Currently, mute doesn't work on Android. Many DLNA players will be discovered by the Emby server and thus made visible in this plugin, but are not controllable (even though Emby's flag for the session says remote control is available). If something works on one player but not another, that's probably a client issue, not a plugin issue, and I will not likely spend a lot of time chasing it.

Emby does not currently maintain an accessible "queue" of items a client is going to play. There is a queue, but it exists only during play, and is not accessible through the Emby API (the author has said he plans to address this in future). That means, for the moment, that you can't simply send a "Play" command to an Emby client and have it pick up from where it was previously stopped. You can start playing from a paused state, no problem, but from a full stop/idle player, there's no history stored to use as a starting point. The Emby plugin makes some attempt to address this limitation by tracking the one last-known media item and providing an action to resume play of that item, but if it was one of many in a long list, there's no way for the plugin to know that and the remainder of the former list cannot be played.

## Special Features

While not every Emby client implements every feature, the plugin does make an effort to get common functionality working using the available capabilities of the client.

### SmartVolume

The Emby remote control API's volume up and down functions rely on the client to do the "right" thing, and many don't. Many simply move the volume up or down by 1%, which isn't very useful--it takes a lot of 1% changes to make a meaningful change in volume. This plugin's "SmartVolume" feature addresses this, when enabled, by avoiding the simple up/down API commands and explicitly setting the volume to an increment from its current value. The feature can be enabled by setting the "SmartVolume" state variable to a non-zero value. This value represents the increment that should be used; that is, if you set it to 10, then volume will be increased or decreased in increments of 10%. When set to 0, SmartVolume is disabled and the up/down control APIs are used (with client-dependent results).

### SmartMute

Not every Emby client implements the Emby remote control API's "ToggleMute" command, so the plugin makes some effort to make mute happen by other means. These are the mechanisms used, in order of preference, chosen based on the capabilities advertised:
* If the server reports that the client supports the "ToggleMute" API command, we'll use that;
* Otherwise, if the client supports the "Mute" and "Unmute" API commands, we'll use those;
* Otherwise, if the client supports direct control of volume, we'll toggle between the last reported volume level and 0%;
* Finally, the plugin will use pause/unpause.

Several clients report that they support "ToggleMute," but the command has no effect (I'm looking at you, Android client version 3.0.28). If you find that you cannot mute, it's likely that the client (or the Emby server) is mis-reporting its capabilities (or there's simply a bug in that version of the client). You can force the plugin to use a different method by setting the "SmartMute" state variable to "volume" or "pause", for direct volume control or pause/unpause behavior, respectively. The default is "auto".

### SmartSkip

I discovered early on that the Emby remote control API's `PreviousTrack` and `NextTrack` commands work for audio, but do nothing when a movie is playing. Moving around a movie makes a bit of sense, so, if a video is playing and has chapter information embedded and reported by the server, the plugin will use that chapter information to seek to the previous or next chapter relative to the current play position. If there is no chapter data in the video, a 30-second skip backward or forward will occur.

### Hiding Sessions and Reducing Device UI Clutter

Emby servers can end up having a lot of clients, and the presentation of all of those clients as child devices in the Vera UI can lead to quite a bit of clutter. Two options for automatically hiding sessions are available: hide offline sessions, and hide idle sessions. The visibility of individual sessions can be controlled via the "Sessions" tab on the Emby Server device. This lets you force hide or show a session, overriding the automatic hiding actions of the plugin if those features are enabled.

## Actions

The following are the various actions that can be performed via the `luup.call_action()` call. Please note the service ID and device type used with each; using the wrong service ID with an action, or attempting an action on a device that doesn't support it, will result in no action being performed.

### Emby Interface Actions

There is a small set of actions you can perform on the Emby Plugin itself (the master device). All of these actions are in the `urn:toggledbits-com:serviceId:Emby1` service.

#### RunDiscovery

The `RunDiscovery` action starts a UDP discovery job. It returns no values and reports no results. If new servers are discovered, child devices are added for them, and Luup will reload.

#### DiscoverIP

The `DiscoverIP` action takes a single parameter: `IPAddress`. The plugin will attempt to contact the Emby server at the given IP address and register it, if it is valid. This is an alternative to UDP discovery, which is not supported currently on openLuup.

### Emby Server Actions

The actions for servers live in the `urn:toggledbits-com:serviceId:EmbyServer1` service and apply to Emby server devices.

#### Authenticate

The `Authenticate` action either logs in with a given username and password (using parameters `Username` and `Password`) and has the server generate an API key, or assigns a user-created API key (provided in the `APIKey` parameter) to the server device. 

To log in as a user, you can create a username and password on your Emby server for the plugin to use, or use an existing username. To create an API key, you go to the "Security" tab in the Emby server's web interface.

Login or key assignment only needs to be done once. The key is valid until revoked, so future connections by the plugin to the server can use the existing key until you revoke it (or change/delete the username/password).

#### Inventory

The `Inventory` action causes the plugin to re-inventory the Emby server and find new active sessions. By default, inventory is only done at Luup startup. Because sessions are Luup child devices, creating them requires a Luup reload, so calling this action will not return if a new client session is found and added.

Startup inventory can be disable by setting the `StartupInventory` state variable to 0.

### Emby Session Actions

Most users will be primarily interested in manipulating sessions. This is where you can have your home theater PC pause and display a message when the doorbell rings, or launch a playlist as part of a scene.

In addition to the actions defined by its own service (described below), sessions implement the following actions of other services:
* In `urn:micasaverde-com:serviceId:MediaNavigation1`
  * The `Pause` action will pause play, and the `Play` action will resume play previously paused. Note that current Emby versions to not have the media queue of the clients available through the API, so the `Play` action cannot be used to resume playing after issuing a `Stop` action to a session.
  * The `Stop` action will stop (completely) whatever media is playing on the client. There is no resume function, currently (see comment above).
  * The `SkipDown` and `SkipUp` actions go to the next and previous, respectively, items in the session's queue. The `ChapterDown` and `ChapterUp` actions are synonyms for `SkipUp` and `SkipDown` respectively. Note the (intentional) up/down reversal here. `ChapterDown` means previous because "down" in chapter context means reduce the current chapter number, while `SkipDown` means "next" because its perspective is that of a playlist, where moving "down" the list means going to the next item. Also, see the description of "SmartSkip" above.
* In service `urn:micasaverde-com:serviceId:Volume1`
  * Actions `Up` and `Down` raise and lower (respectively) the volume of the Emby client. These actions take no parameters. Note that this often controls the volume level of the Emby *client* and not that of the *device* on which the client is running. It is possible for the client to be at 100% volume, while the device (e.g. Android phone or tablet) is muted at the system level. Emby may not have control of the device volume. Also, see the discussion of "SmartVolume" above under "Special Features". To set an absolute volume level, you can use the `SetVolume` action in the `urn:toggledbits-com:serviceId:EmbySession1` service (described below).
  * Action `Mute` mutes or unmutes the client (toggles). The current muting state can be found by examining the `Mute` state variable for the session in this Volume1 service).
  
The following are the actions defined for sessions by the `urn:toggledbits-com:serviceId:EmbySession1` service:

#### PlayMedia

The `PlayMedia` action launches play of a media item (or several). The action performs a search for media using the provided parameters, and launches play with the search result. The following parameters are defined:
* `Id` (required if `Title` not provided) - An Emby item ID, or comma-separated list of IDs, to play;
* `Title` (required if `Id` not provided) - The title (or part of it) to search for (e.g. "Master of Puppets");
* `MediaType` (optional) - If specified, must be an Emby-recognized media type (e.g. Audio, Movie, MusicAlbum, Playlist, etc.);
* 'Limit` (optional) - If specified, the maximum number of matching items to play (if not specified or less than 1, 25 is used);
* 'PlayCommand' (optional) - If specified, must be "PlayNow", "PlayNext", or "PlayLast" (default is PlayNow). This controls how the items are added to the session's queue; PlayNow replaces the current queue; PlayNext inserts the items after the current playing item; PlayLast appends the items to the queue.

`luup.call_action( "urn:toggledbits-com:serviceId:EmbySession1", "PlayMedia", { Title="Master of Puppets", MediaType="Audio" }, sessionDeviceNum )`

The most reliable/predictable way to play a single media item is to use its ID. To find the item's ID, browse to it in the web interface. Then look at the URL--the ID is a parameter on the URL and easily discerned.

#### PlayPause

Because the `MediaNavigation1` service has separate `Play` and `Pause` actions but no toggle, the `PlayPause` action in this service provides that feature. It takes no parameters.

#### ViewMedia

The `ViewMedia` action moves the client's user interface to the given media item. It does not start play; it just moves the UI. The following parameters are used:
* `Id` (required if `Title` is not specified) - The media ID (recommended);
* `Title` (required if `Id` is not specified) - The title of the media item;
* `MediaType` (optional) - The Emby media type of the item (only used when Title is given and Id is not), to help narrow the search result.

#### ResumeMedia

The `ResumeMedia` action is a plugin-provided enhancement. Currently, Emby servers do not offer API access to the queue of clients--we can see the media item that is currently playing, but not what played previously or may be playing next. As a result, when you `Stop` play on an Emby session, there is no Emby way to resume plaing the full queue (as one can do on Sonos, for example, where the queue is treated as a persistent, anonymous playlist). The action simply restarts play of the last known playing media item at the last checkpoint recorded. The optional `Restart` parameter may be given as "1" to force the media item to start playing from its beginning rather than the checkpoint.

#### SetVolume

The `SetVolume` action takes a single parameter, `Volume` (0-100), and sets the volume of the client accordingly. See note about volume in the discussion of the `Up` and `Down` volume actions in the `urn:micasaverde-com:serviceId:Volume1` service, above.

#### Message

The `Message` action causes a message to display on the Emby client (if active). Parameters:
* `Text` (required) - Text of the message to display;
* `Header` (optional) - Text of the dialog box title (only shows when `TimeoutMs` is not specified;
* `TimeoutMs` (optional) - Timeout for the message display. **CAUTION** The name of this parameter (same as that used in the Emby API) may lead one to believe that the value is expressed in milliseconds, but that does not appear to be case (perhaps the "Ms" stands for "message"?). If given, the dialog box will appear without a header and without an "OK" button to clear it, and will display for the given number of seconds (there is no way to clear it). If `TimeoutMs` is not provided, a modal dialog with the header text and an "OK" button will appear.

#### Refresh

The `Refresh` action forces the plugin to re-query the session state and update the display. Avoid invoking this action frequently, as it creates a load on both the Vera and Emby server for very little benefit.

## LICENSE

This Emby plugin for Vera is currently not open source. You may use it freely on your Vera or openLuup device, but you may not distribute it in whole or part, or produce derivative works.
