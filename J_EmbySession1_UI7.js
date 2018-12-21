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
    var uuid = '52876cfe-0471-11e9-88ed-74d4351650de';

    var myModule = {};

    var serviceId = "urn:toggledbits-com:serviceId:EmbySession1";
    // var deviceType = "urn:schemas-toggledbits-com:device:EmbySession:1";

    var iData = [];

    /* Return footer */
    function footer() {
        var html = '';
        html += '<div class="clearfix">';
        html += '<div id="tbbegging"><em>Find Reactor useful?</em> Please consider a small one-time donation to support this and my other plugins on <a href="https://www.toggledbits.com/donate" target="_blank">my web site</a>. I am grateful for any support you choose to give!</div>';
        html += '<div id="tbcopyright">Reactor ver 2.0beta-18121701 &copy; 2018 <a href="https://www.toggledbits.com/" target="_blank">Patrick H. Rigney</a>,' +
            ' All Rights Reserved. Please check out the <a href="https://www.toggledbits.com/reactor" target="_blank">online documentation</a>' +
            ' and <a href="http://forum.micasaverde.com/index.php/board,93.0.html" target="_blank">forum board</a> for support.</div>';
        html += '<div id="supportlinks">Support links: ' +
            ' <a href="' + api.getDataRequestURL() + '?id=lr_Reactor&action=debug" target="_blank">Toggle&nbsp;Debug</a>' +
            ' &bull; <a href="/cgi-bin/cmh/log.sh?Device=LuaUPnP" target="_blank">Log&nbsp;File</a>' +
            ' &bull; <a href="' + api.getDataRequestURL() + '?id=lr_Reactor&action=status" target="_blank">Plugin&nbsp;Status</a>' +
            ' &bull; <a href="' + api.getDataRequestURL() + '?id=lr_Reactor&action=summary&device=' + api.getCpanelDeviceId() + '" target="_blank">Logic&nbsp;Summary</a>' +
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
        initModule: initModule
    };
    return myModule;
})(api, $ || jQuery);
