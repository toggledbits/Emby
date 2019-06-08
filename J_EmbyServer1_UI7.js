//# sourceURL=J_EmbyServer1_UI7.js
/**
 * J_EmbyServer1_UI7.js
 * Configuration interface for EmbyServer
 *
 * Copyright 2018 Patrick H. Rigney, All Rights Reserved.
 */
/* globals api,jQuery,$ */

//"use strict"; // fails on UI7, works fine with ALTUI

var EmbyServer = (function(api, $) {

	var pluginVersion = '1.2';

	/* unique identifier for this plugin... */
	var uuid = 'fbef24d8-0bc1-11e9-b678-74d4351650de'; //EmbyServer190103

	var myModule = {};

	var serviceId = "urn:toggledbits-com:serviceId:EmbyServer1";
	// var deviceType = "urn:schemas-toggledbits-com:device:EmbyServer:1";

	var iData = [];

	/* Insert header items */
	function header() {
		// jQuery( '<head>' ).append( ... );
	}

	/* Return footer */
	function footer() {
		var html = '';
		html += '<div class="clearfix">';
		html += '<div id="tbbegging"><em>Find this plugin useful?</em> Please consider a small donation to support this and my other plugins on <a href="https://www.toggledbits.com/donate" target="_blank">my web site</a>. I am grateful for any support you choose to give!</div>';
		html += '<div id="tbcopyright">Emby Plugin ver ' + pluginVersion + ' &copy; 2018,2019 <a href="https://www.toggledbits.com/" target="_blank">Patrick H. Rigney</a>,' +
			' All Rights Reserved. Please check out the <a href="https://github.com/toggledbits/Emby/" target="_blank">online documentation</a>' +
			' and <a href="http://forum.micasaverde.com/index.php/topic,118013.0.html" target="_blank">forum thread</a> for support.</div>';
		return html;
	}

	/* Initialize the module */
	function initModule() {
		var myid = api.getCpanelDeviceId();
		console.log("initModule() for device " + myid);

		/* Instance data */
		iData[myid] = { };
	}

	function handleSessionVisibilityChange( ev ) {
		var mm = jQuery( ev.currentTarget );
		var id = parseInt( mm.attr( 'id' ) );
		var newval = mm.val();
		api.setDeviceStateVariablePersistent( id, "urn:toggledbits-com:serviceId:EmbySession1", "Visibility", newval || "auto" );
	}

	function handleServerOptionChange( ev ) {
		var opt = jQuery( ev.currentTarget );
		var checked = opt.prop( 'checked' );
		var setting = opt.attr( 'id' ) === "hideidle" ? "HideIdle" : "HideOffline";
		api.setDeviceStateVariablePersistent( api.getCpanelDeviceId(), serviceId, setting, checked ? "1" : "0" );
	}

	function doSessions() {
		initModule();

		header();

		var html = '<div id="sessions" class="embytab" />';
		html += footer();
		api.setCpanelContent( html );

		var container = jQuery( 'div#sessions.embytab' );
		container.append( '<div class="row"><div class="col-xs-12 col-lg-12 form-inline"><label><input type="checkbox" id="hideoffline"> Auto-hide off-line sessions</label> <label><input type="checkbox" id="hideidle"> Auto-hide idle sessions</label></div></div>' );
		var myid = api.getCpanelDeviceId();
		var s = api.getDeviceState( myid, serviceId, "HideOffline" ) || "0";
		jQuery( "input#hideoffline", container ).prop( 'checked', "0" !== s );
		s = api.getDeviceState( myid, serviceId, "HideIdle" ) || "0";
		jQuery( "input#hideidle", container ).prop( 'checked', "0" !== s );
		jQuery( "input", container ).on( 'change.emby', handleServerOptionChange );

		var mm = jQuery( '<select class="vismenu form-control form-control-sm" />' );
		mm.append( jQuery( '<option/>' ).val('auto').text('Auto') );
		mm.append( jQuery( '<option/>' ).val('show').text('Always Show') );
		mm.append( jQuery( '<option/>' ).val('hide').text('Always Hide') );

		var ud = api.getUserData();
		var pluginDevice = ud.devices[ api.getDeviceIndex( myid ) ].id_parent;
		for ( var ix=0; ix<(ud.devices || []).length; ++ix ) {
			if ( ud.devices[ix].id_parent == pluginDevice && ud.devices[ix].device_type == "urn:schemas-toggledbits-com:device:EmbySession:1" ) {
				var devnum = ud.devices[ix].id;

				/* Build row for display */
				var row = jQuery( '<div class="row" />' );
				row.attr( 'id', devnum );
				var el = jQuery( '<div class="col-xs-8 col-lg-4" />' );
				el.append( ud.devices[ix].name + ' (#' + devnum + ')' );
				row.append( el );
				el = jQuery( '<div class="col-xs-4 col-lg-2" />' );
				el.append( mm.clone().attr( 'id', devnum ).on( 'change.emby', handleSessionVisibilityChange ) );
				row.append( el );
				jQuery( 'div#sessions.embytab' ).append( row );

				/* Restore current setting */
				s = api.getDeviceState( devnum, "urn:toggledbits-com:serviceId:EmbySession1", "Visibility" );
				jQuery( 'select#' + devnum, row ).val( s );
			}
		}
	}

	console.log("Initializing EmbyServer module");

	myModule = {
		uuid: uuid,
		initModule: initModule,
		doSessions: doSessions
	};
	return myModule;
})(api, $ || jQuery);
