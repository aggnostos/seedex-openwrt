'use strict';
'require view';
'require ui';
'require poll';
'require dom';
'require seedex.api as api';

var SVC = 'router';

var SETTINGS = [
	{ key: 'default_route', label: _('Default route'),
	  options: [ [ 'overlay', _('overlay — everything through the tunnel, rules make exceptions') ],
	             [ 'direct', _('direct — everything via WAN, rules pick what goes through the tunnel') ] ] },
	{ key: 'kill_switch', label: _('Kill switch'),
	  options: [ [ '1', _('on — traffic meant for the tunnel is dropped when no tunnel is up') ],
	             [ '0', _('off — it falls back to the WAN') ] ] },
	{ key: 'watchdog_mode', label: _('Watchdog mode'),
	  options: [ [ 'fastest', _('fastest — move to a clearly faster tunnel') ],
	             [ 'priority', _('priority — move to a tunnel of higher priority, never for speed') ],
	             [ 'failover', _('failover — stay on a tunnel until it fails') ] ] },
	{ key: 'watchdog_interval', label: _('Watchdog interval'), placeholder: '30', hint: _('seconds') },
	{ key: 'watchdog_timeout', label: _('Watchdog timeout'), placeholder: '5', hint: _('seconds') },
	{ key: 'watchdog_url', label: _('Watchdog URL'), placeholder: 'https://www.gstatic.com/generate_204' },
	{ key: 'watchdog_tolerance', label: _('Switch margin'), placeholder: '100',
	  hint: _('ms: in fastest mode, another tunnel must be faster by more than this') },
	{ key: 'watchdog_checks', label: _('Switch checks'), placeholder: '3',
	  hint: _('probes in a row the better tunnel must win before the switch') }
];

function splitList(text) {
	return text.split(/[\s,]+/).filter(function(v) { return v !== ''; });
}

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
			this.renderRules(refresh),
			api.settingsCard(SVC, SETTINGS, this.values, refresh, this)
		];
	},

	renderRules: function(refresh) {
		var self = this;
		var rows = api.sections(self.values, 'rule').map(function(s) {
			var name = s.name || s['.name'];
			var enabled = s.enabled == '1';
			var domains = L.toArray(s.domain).length;
			var ips = L.toArray(s.ip).length;
			var clients = L.toArray(s.client_mac).length + L.toArray(s.client_ip).length;
			var source = [];
			if (clients) source.push(_('%d clients').format(clients));
			if (domains) source.push(_('%d domains').format(domains));
			if (ips) source.push(_('%d IPs').format(ips));
			if (s.list_url) source.push(_('URL list'));
			if (s.list_path) source.push(_('file list'));

			return [ api.mark(enabled), name, s.type || '—', s.iface || '—', source.join(' + ') || _('(empty)'),
				E('div', {}, [
					api.button(_('Edit'), 'cbi-button-action', function() {
						return self.openEditor(s, refresh);
					}, self),
					' ',
					api.button(enabled ? _('Disable') : _('Enable'), 'cbi-button-neutral', function() {
						return api.run(SVC, enabled ? 'disable' : 'enable', [ name ]).catch(api.fail).then(refresh);
					}, self),
					' ',
					api.button(_('Remove'), 'cbi-button-remove', function() {
						if (!confirm(_('Remove rule "%s"?').format(name)))
							return Promise.resolve();
						return api.run(SVC, 'remove', [ name ]).catch(api.fail).then(refresh);
					}, self)
				]) ];
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Rules')),
			api.table([ '', _('Name'), _('Type'), _('Tunnel'), _('Source'), '' ], rows, _('No rules yet')),
			E('div', { 'class': 'cbi-page-actions' }, [
				api.button(_('Add rule'), 'cbi-button-add', function() {
					return self.openEditor(null, refresh);
				}, self)
			])
		]);
	},

	openEditor: function(s, refresh) {
		var self = this;
		var isNew = !s;
		s = s || {};
		var oldName = s.name || s['.name'] || '';

		var name = api.input(oldName, 'youtube');
		var type = api.select(s.type || 'overlay', [
			[ 'overlay', _('overlay — send through the tunnel') ],
			[ 'direct', _('direct — send via WAN') ],
			[ 'block', _('block — NXDOMAIN for domains, drop for IPs') ]
		]);
		var macs = api.textarea(L.toArray(s.client_mac).join('\n'), 3, 'aa:bb:cc:dd:ee:ff');
		var clientIps = api.textarea(L.toArray(s.client_ip).join('\n'), 3, '192.168.1.20\n10.0.20.0/24');
		var domains = api.textarea(L.toArray(s.domain).join('\n'), 6, 'youtube.com\ngooglevideo.com');
		var ips = api.textarea(L.toArray(s.ip).join('\n'), 4, '1.1.1.1\n10.0.0.0/8\n2606:4700::/32');
		var listUrl = api.input(s.list_url, 'https://example.org/domains.txt');
		var listPath = api.input(s.list_path, '/etc/seedex/lists/custom.txt');
		var listRefresh = api.input(s.list_refresh, '12h');
		var iface = api.input(s.iface, 'nl1-awg-router');
		var oldDns = L.toArray(s.dns).join(', ');
		var dns = api.input(oldDns, 'default');

		var save = function() {
			var n = name.value.trim();
			if (!n)
				return Promise.reject(new Error(_('Name is required')));
			var args = [];
			var pin = iface.value.trim();
			if (isNew) {
				args.push(n, 'type=' + type.value);
				if (pin)
					args.push('iface=' + pin);
			}
			else {
				args.push(oldName);
				if (n !== oldName)
					args.push('name=' + n);
				if (pin !== (s.iface || ''))
					args.push('iface=' + pin);
				if (type.value !== (s.type || 'overlay'))
					args.push('type=' + type.value);
			}
			// Only what the user changed: 'domain=a,b' replaces the list, so an
			// unchanged one would still show up as pending.
			// What a save clears goes first: a rule turning from destinations
			// to clients must lose its domains and lists before it takes a MAC.
			var lists = [ [ macs, 'client_mac' ], [ clientIps, 'client_ip' ], [ domains, 'domain' ], [ ips, 'ip' ] ]
				.map(function(f) {
					var list = splitList(f[0].value), old = L.toArray(s[f[1]]);
					if (f[1] === 'client_mac') {
						list = list.map(function(v) { return v.toLowerCase(); });
						old = old.map(function(v) { return v.toLowerCase(); });
					}
					return [ f[1], list, list.join(',') !== old.join(','), old ];
				}).filter(function(l) { return l[2]; });
			lists.filter(function(l) { return !l[1].length; }).forEach(function(l) {
				args.push(l[0] + '=');
			});
			[ [ listUrl, 'list_url', 'del-url' ],
			  [ listPath, 'list_path', 'del-path' ],
			  [ listRefresh, 'list_refresh', 'del-refresh' ] ].forEach(function(f) {
				var v = f[0].value.trim();
				if (v === (s[f[1]] || ''))
					return;
				args.push(v ? f[1] + '=' + v : f[2]);
			});
			// A list that keeps entries changes by them alone: add-domain=,
			// del-domain=, so that the pending changes show just those.
			lists.filter(function(l) { return l[1].length; }).forEach(function(l) {
				var gone = l[3].filter(function(v) { return l[1].indexOf(v) < 0; });
				var added = l[1].filter(function(v) { return l[3].indexOf(v) < 0; });
				if (!l[3].length || gone.length + added.length >= l[1].length) {
					args.push(l[0] + '=' + l[1].join(','));
					return;
				}
				if (gone.length)
					args.push('del-' + l[0] + '=' + gone.join(','));
				if (added.length)
					args.push('add-' + l[0] + '=' + added.join(','));
			});
			var servers = splitList(dns.value).filter(function(v) { return v !== 'default'; }).join(',');
			if (isNew ? servers : servers !== splitList(oldDns).join(','))
				args.push('dns=' + (servers || 'default'));
			if (!isNew && args.length === 1) {
				ui.hideModal();
				return Promise.resolve();
			}
			return api.run(SVC, isNew ? 'add' : 'update', args)
				.then(ui.hideModal, api.fail).then(refresh);
		};

		ui.showModal(isNew ? _('Add rule') : oldName, [
			api.field(_('Name'), name),
			api.field(_('Type'), type),
			api.field(_('Tunnel'), iface, _('Name of a VPN or proxy config; empty means the fastest tunnel')),
			api.field(_('Client MACs'), macs, _('Whole-client rule: all traffic from these devices; cannot be combined with destinations')),
			api.field(_('Client IPs'), clientIps, _('Devices or subnets by address, e.g. a guest VLAN; same rule as MACs')),
			api.field(_('Domains'), domains, _('One per line; subdomains are matched too')),
			api.field(_('IPs'), ips, _('IPv4 or IPv6 addresses and CIDR ranges, one per line')),
			api.field(_('List URL'), listUrl, _('Downloaded when the router starts')),
			api.field(_('List file'), listPath, _('A local file on the router')),
			api.field(_('List refresh'), listRefresh, _('e.g. 12h or 1d')),
			api.field(_('DNS'), dns, _('Servers for the rule\'s domains, e.g. 10.0.0.53; queries take the rule\'s path. default means the DNS service')),
			api.modalActions(isNew ? _('Add') : _('Save'), save, self)
		]);
		return Promise.resolve();
	}
});
