'use strict';
'require view';
'require poll';
'require dom';
'require seedex.api as api';

var SVC = 'dns';

var SETTINGS = [
	{ key: 'upstream', label: _('Upstream'),
	  options: [ [ 'encrypted', _('encrypted — DNS-over-HTTPS, through the tunnel when one is up') ],
	             [ 'plain', _('plain — the resolver\'s classic DNS, same path') ],
	             [ 'provider', _('provider — whatever the WAN handed out, untouched') ] ] },
	{ key: 'resolver', label: _('Resolver'),
	  options: [ [ 'cloudflare', 'Cloudflare' ], [ 'quad9', 'Quad9' ], [ 'google', 'Google' ] ] },
	{ key: 'intercept', label: _('Interception'),
	  options: [ [ '1', _('on — every LAN DNS query goes through the router, DoT is refused') ],
	             [ '0', _('off — clients may use any resolver and bypass the rules') ] ] }
];

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return Promise.all([ api.status(), api.config(SVC) ]);
	},

	refresh: function() {
		var self = this;
		return Promise.all([ api.status(), api.config(SVC) ]).then(function(r) {
			self.status = r[0];
			self.values = r[1];
			dom.content(self.body, self.renderBody());
		}, api.fail);
	},

	render: function(data) {
		this.status = data[0];
		this.values = data[1];
		this.body = E('div', {}, this.renderBody());
		poll.add(L.bind(this.refresh, this), 10);
		return E('div', {}, [
			E('h2', {}, 'Seedex ' + api.labels[SVC]),
			this.body
		]);
	},

	renderBody: function() {
		var refresh = L.bind(this.refresh, this);
		return [
			api.serviceHeader(SVC, this.status, refresh, this),
			api.pendingBanner(SVC, this.status, refresh, this),
			api.settingsCard(SVC, SETTINGS, this.values, refresh, this)
		];
	}
});
