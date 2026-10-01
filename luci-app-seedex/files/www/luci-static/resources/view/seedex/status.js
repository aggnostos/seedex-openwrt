'use strict';
'require view';
'require poll';
'require dom';
'require seedex.api as api';

var SERVICES = [ 'router', 'vpn', 'proxy', 'dns' ];

var REASONS = {
	router_stopped: _('the router is stopped'),
	stale: _('the watchdog has not reported lately'),
	no_interfaces: _('no tunnel is up'),
	all_unreachable: _('no tunnel answers')
};

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return api.status();
	},

	refresh: function() {
		var self = this;
		return api.status().then(function(status) {
			self.status = status;
			dom.content(self.body, self.renderBody());
		}, api.fail);
	},

	render: function(status) {
		this.status = status;
		this.body = E('div', {}, this.renderBody());
		poll.add(L.bind(this.refresh, this), 5);
		return E('div', {}, [
			E('h2', {}, 'Seedex'),
			this.body
		]);
	},

	renderBody: function() {
		var s = this.status;
		var refresh = L.bind(this.refresh, this);
		var act = function(svc, action) {
			return function() {
				return api.run(svc, action).catch(api.fail).then(refresh);
			};
		};
		var svcRows = SERVICES.map(function(svc) {
			var running = api.running(s, svc);
			return [ api.mark(running), api.labels[svc], running ? _('running') : _('stopped'),
				E('div', {}, [
					api.button(running ? _('Stop') : _('Start'), 'cbi-button-action',
						act(svc, running ? 'stop' : 'start'), this),
					' ',
					api.button(_('Restart'), 'cbi-button-action', act(svc, 'restart'), this)
				]) ];
		}, this);

		var u = s.uplink || {}, inet = u.internet || {}, ov = u.overlay || {};
		var uplinkRows = [
			[ api.mark(inet.up), _('Internet'), '',
			  inet.up ? '%d ms'.format(inet.rtt) : _('unreachable') ],
			[ api.mark(ov.up), _('Overlay'),
			  ov.up ? ov.tunnel + (ov.via ? ' (' + ov.via + ')' : '') : '',
			  ov.up ? (ov.rtt != null ? '%d ms'.format(ov.rtt) : '') : (REASONS[ov.reason] || ov.reason || '') ]
		];

		var stopAll = function() {
			if (!confirm(_('Stop every Seedex service? Traffic leaves through the provider until they start again.')))
				return Promise.resolve();
			return act('', 'stop')();
		};

		return [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Uplink')),
				api.table([ '', '', _('Tunnel'), _('RTT') ], uplinkRows)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Services')),
				E('div', {}, [
					api.button(_('Start all'), 'cbi-button-action', act('', 'start'), this),
					' ',
					api.button(_('Stop all'), 'cbi-button-negative', stopAll, this),
					' ',
					api.button(_('Restart all'), 'cbi-button-action', act('', 'restart'), this)
				]),
				api.table([ '', '', _('State'), '' ], svcRows)
			])
		];
	}
});
