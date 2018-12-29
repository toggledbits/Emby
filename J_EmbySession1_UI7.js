//# sourceURL=J_EmbySession1_UI7.js
/**
 * J_EmbySession1_UI7.js
 * Configuration interface for EmbySession
 *
 * Copyright 2018 Patrick H. Rigney, All Rights Reserved.
 */
/* globals api,jQuery,$ */

//"use strict"; // fails on UI7, works fine with ALTUI

var EmbySession = (function(api, $) {

    /* unique identifier for this plugin... */
    var uuid = 'fbef24d8-0bc1-11e9-a678-74d4351650de'; //EmbySession181229

    var myModule = {};

    var serviceId = "urn:toggledbits-com:serviceId:EmbySession1";
    // var deviceType = "urn:schemas-toggledbits-com:device:EmbySession:1";

    var iData = [];

    /* Return footer */
    function footer() {
        var html = '';
        html += '<div class="clearfix">';
        html += '<div id="tbbegging"><em>Find Emby Plugin useful?</em> Please consider a small one-time donation to support this and my other plugins on <a href="https://www.toggledbits.com/donate" target="_blank">my web site</a>. I am grateful for any support you choose to give!</div>';
        html += '<div id="tbcopyright">Emby Plugin ver 2.0beta-18121701 &copy; 2018 <a href="https://www.toggledbits.com/" target="_blank">Patrick H. Rigney</a>,' +
            ' All Rights Reserved. Please check out the <a href="https://www.toggledbits.com/reactor" target="_blank">online documentation</a>' +
            ' and <a href="http://forum.micasaverde.com/index.php/board,93.0.html" target="_blank">forum board</a> for support.</div>';
        html += '<div id="supportlinks">Support links: ' +
            ' <a href="' + api.getDataRequestURL() + '?id=lr_Emby Plugin&action=debug" target="_blank">Toggle&nbsp;Debug</a>' +
            ' &bull; <a href="/cgi-bin/cmh/log.sh?Device=LuaUPnP" target="_blank">Log&nbsp;File</a>' +
            ' &bull; <a href="' + api.getDataRequestURL() + '?id=lr_Emby Plugin&action=status" target="_blank">Plugin&nbsp;Status</a>' +
            ' &bull; <a href="' + api.getDataRequestURL() + '?id=lr_Emby Plugin&action=summary&device=' + api.getCpanelDeviceId() + '" target="_blank">Logic&nbsp;Summary</a>' +
            '</div>';
        return html;
    }

    /* Evaluate input string as integer, strict (no non-numeric chars allowed other than leading/trailing whitespace, empty string fails). */
    function getInteger( s ) {
        s = String(s).replace( /^\s+|\s+$/gm, '' );
        s = s.replace( /^\+/, '' ); /* leading + is fine, ignore */
        if ( s.match( /^-?[0-9]+$/ ) ) {
            return parseInt( s );
        }
        return NaN;
    }

    /* Like getInteger(), but returns dflt if no value provided (blank/all whitespace) */
    function getOptionalInteger( s, dflt ) {
        if ( String(s).match( /^\s*$/ ) ) {
            return dflt;
        }
        return getInteger( s );
    }

    /* Initialize the module */
    function initModule() {
        var myid = api.getCpanelDeviceId();
        console.log("initModule() for device " + myid);

        /* Instance data */
        iData[myid] = { };
    }

    function isEmpty( s ) {
        return s === undefined || s === "";
    }

    function quot( s ) {
        if ( typeof(s) != "string" ) s = String(s);
        return '"' + s.replace( /"/g, "\\\"" ) + '"';
    }

    function insertIfNotEmpty( obj, key, val ) {
        if ( undefined === val || "" === val ) {
            return;
        }
        obj[key] = val;
    }

    function updateResults() {
        var container = jQuery( 'div#embyresults' );
        container.empty();
        var folder = jQuery( 'div#emby-mediaplayer div#embyfilters select#folder' ).val();
        var type = jQuery( 'div#emby-mediaplayer div#embyfilters select#type' ).val() || "";
        var artist = jQuery( 'div#emby-mediaplayer div#embyfilters select#artist' ).val() || "";
        var album = jQuery( 'div#emby-mediaplayer div#embyfilters select#album' ).val() || "";

        var ea = { Recursive: true, Limit: 100 };
        insertIfNotEmpty( ea, 'IncludeItemTypes', type );
        insertIfNotEmpty( ea, 'ArtistIds', artist );
        insertIfNotEmpty( ea, 'AlbumIds', album );
        ea.api_key = apikey;
        jQuery.ajax({
            url: "http://192.168.0.165:8096/emby/Library/Users/" + userid + "/Items",
            data: ea,
            dataType: "json",
            timeout: 15000
        }).done( function( data, statusText, jqXHR ) {
            console.log( "got data?" );
        }).fail( function() {
            container.append("Results could not be retrieved");
        });
    }

    function handleFolderSelect( ev ) {
        var fid = jQuery( ev.currentTarget ).val();
        jQuery( 'div#emby-mediaplayer div#embyfilters select#artist' ).empty().hide().attr( 'disabled', true );
        jQuery( 'div#emby-mediaplayer div#embyfilters select#album' ).empty().hide().attr( 'disabled', true );
        jQuery( 'div#embyresults' ).empty();
        if ( "" === fid ) {
            return;
        }
        jQuery( 'div#emby-mediaplayer div#embyfilters select#type' ).empty().hide().attr( 'disabled', true );
        updateResults();
    }

    function doMediaPlayer() {
        var html;

        html = '<div id="emby-mediaplayer">';
            html += '<div id="nowplaying">';
                html += '<div id="nowplaying-art">image</div>';
                html += '<div id="nowplaying-info">info</div>';
            html += '</div>'; // #nowplaying
            html += '<div class="row">';
                html += '<div class="form-inline col-xs-12"><button id="voldown" class="embyvol btn btn-sm btn-primary">-</button><button id="volup" class="embyvol btn btn-sm btn-primary">+</button><input id="volval" class="embyvol form-control form-control-sm"><button id="volset" class="embyvol btn btn-sm btn-primary">Set</button></div>';
            html += '</div>'; // row
            html += '<div id="embyfilters" class="row">';
                html += '<div class="form-inline col-xs-12"><select id="folder" class="form-control form-control-sm"/><select id="type" class="form-control form-control-sm"/><select id="artist" class="form-control form-control-sm"/><select id="album" class="form-control form-control-sm"/></div>';
            html += '</div>'; // row
            html += '<div id="embyresults"/>';
        html += '</div>'; // #emby-mediaplayer

        api.setCpanelContent( html );

        /* Fetch the folders */
        jQuery.ajax({
            url: "http://192.168.0.165:8096/emby/Library/SelectableMediaFolders?api_key=",
            data: {
                api_key: apikey
            },
            dataType: "json",
            timeout: 15000
        }).done( function( data, statusText, jqXHR ) {
            var menu = jQuery( 'div#emby-mediaplayer div#embyfilters select#folder' );
            menu.empty().append( jQuery('<option/>').val("").text("--choose folder--") );
            for ( var k=0; k<(data||[]).length; ++k ) {
                var lib = data[k];
                var opt = jQuery( '<option/>' );
                opt.text( lib.Name || "?" );
                opt.val( lib.Id || "" );
                menu.append( opt );
            }
            menu.off( 'change.emby' ).on( 'change.emby', handleFolderSelect );
        }).fail( function() {
            jQuery('div#emby-mediaplayer').empty().append('Can\'t load data. Vera may be temporarily unavailable (reloading?). Try again in a moment.');
        });
    }

    console.log("Initializing EmbySession module");

    myModule = {
        uuid: uuid,
        initModule: initModule,
        doMediaPlayer: doMediaPlayer
    };
    return myModule;
})(api, $ || jQuery);
//# sourceURL=J_EmbySession1_UI7.js
/**
 * J_EmbySession1_UI7.js
 * Configuration interface for EmbySession
 *
 * Copyright 2018 Patrick H. Rigney, All Rights Reserved.
 */
/* globals api,jQuery,$ */

//"use strict"; // fails on UI7, works fine with ALTUI

var EmbySession = (function(api, $) {

    /* unique identifier for this plugin... */
    var uuid = '52876cfe-0471-11e9-88ed-74d4351650df';

    var apikey = "4cf74c1489f64750982e1f91bfbca274"; // ??? hard coded!
    var userid = "d9d387e965c444ed87fbcbd8ee362386"; // ??? hard coded!

    var myModule = {};

    var serviceId = "urn:toggledbits-com:serviceId:EmbySession1";
    // var deviceType = "urn:schemas-toggledbits-com:device:EmbySession:1";

    var iData = [];

    /* Return footer */
    function footer() {
        var html = '';
        html += '<div class="clearfix">';
        html += '<div id="tbbegging"><em>Find Emby Plugin useful?</em> Please consider a small one-time donation to support this and my other plugins on <a href="https://www.toggledbits.com/donate" target="_blank">my web site</a>. I am grateful for any support you choose to give!</div>';
        html += '<div id="tbcopyright">Emby Plugin ver 2.0beta-18121701 &copy; 2018 <a href="https://www.toggledbits.com/" target="_blank">Patrick H. Rigney</a>,' +
            ' All Rights Reserved. Please check out the <a href="https://www.toggledbits.com/reactor" target="_blank">online documentation</a>' +
            ' and <a href="http://forum.micasaverde.com/index.php/board,93.0.html" target="_blank">forum board</a> for support.</div>';
        html += '<div id="supportlinks">Support links: ' +
            ' <a href="' + api.getDataRequestURL() + '?id=lr_Emby Plugin&action=debug" target="_blank">Toggle&nbsp;Debug</a>' +
            ' &bull; <a href="/cgi-bin/cmh/log.sh?Device=LuaUPnP" target="_blank">Log&nbsp;File</a>' +
            ' &bull; <a href="' + api.getDataRequestURL() + '?id=lr_Emby Plugin&action=status" target="_blank">Plugin&nbsp;Status</a>' +
            ' &bull; <a href="' + api.getDataRequestURL() + '?id=lr_Emby Plugin&action=summary&device=' + api.getCpanelDeviceId() + '" target="_blank">Logic&nbsp;Summary</a>' +
            '</div>';
        return html;
    }

    /* Evaluate input string as integer, strict (no non-numeric chars allowed other than leading/trailing whitespace, empty string fails). */
    function getInteger( s ) {
        s = String(s).replace( /^\s+|\s+$/gm, '' );
        s = s.replace( /^\+/, '' ); /* leading + is fine, ignore */
        if ( s.match( /^-?[0-9]+$/ ) ) {
            return parseInt( s );
        }
        return NaN;
    }

    /* Like getInteger(), but returns dflt if no value provided (blank/all whitespace) */
    function getOptionalInteger( s, dflt ) {
        if ( String(s).match( /^\s*$/ ) ) {
            return dflt;
        }
        return getInteger( s );
    }

    /* Initialize the module */
    function initModule() {
        var myid = api.getCpanelDeviceId();
        console.log("initModule() for device " + myid);

        /* Instance data */
        iData[myid] = { };
    }

    function isEmpty( s ) {
        return s === undefined || s === "";
    }

    function quot( s ) {
        if ( typeof(s) != "string" ) s = String(s);
        return '"' + s.replace( /"/g, "\\\"" ) + '"';
    }

    console.log("Initializing EmbySession module");

    myModule = {
        uuid: uuid,
        initModule: initModule,
    };
    return myModule;
})(api, $ || jQuery);
