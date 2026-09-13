'use strict';
'require view';
'require poll';
'require dom';
'require seedex.api as api';

var SERVICES = [ 'router', 'vpn', 'proxy', 'dns' ];

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

		return [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Services')),
				api.table([ '', '', _('State'), '' ], svcRows)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('pre', {}, s.text || '')
			])
		];
	}
});
