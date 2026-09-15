'use strict';
'require view';
'require ui';
'require poll';
'require dom';
'require seedex.api as api';

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return api.links();
	},

	refresh: function() {
		var self = this;
		return api.links().then(function(links) {
			self.links = links;
			dom.content(self.body, self.renderBody());
		}, api.fail);
	},

	render: function(links) {
		this.links = links;
		this.body = E('div', {}, this.renderBody());
		poll.add(L.bind(this.refresh, this), 30);
		return E('div', {}, [
			E('h2', {}, 'Seedex ' + api.labels.link),
			this.body
		]);
	},

	renderBody: function() {
		var self = this;
		var refresh = L.bind(this.refresh, this);
		var act = function(args) {
			return api.run('', 'link', args).then(api.notify, api.fail).then(refresh);
		};

		var rows = this.links.map(function(l) {
			var selection = l.selected.indexOf('*') >= 0 ? _('everything')
			              : l.selected.length ? l.selected.join(', ') : _('nothing');
			return [
				api.mark(l.ok),
				l.name,
				l.url,
				'%d vpn, %d proxy'.format(l.vpn, l.proxy),
				selection,
				l.when,
				E('div', {}, [
					api.button(_('Configs'), 'cbi-button-action', function() {
						return self.openConfigs(l, refresh);
					}, self),
					' ',
					api.button(_('Sync'), 'cbi-button-neutral', function() {
						return act([ 'sync', l.name ]);
					}, self),
					' ',
					api.button(_('Remove'), 'cbi-button-remove', function() {
						if (!confirm(_('Unpair "%s" and drop the configs it delivered?').format(l.name)))
							return Promise.resolve();
						return act([ 'remove', l.name ]);
					}, self)
				])
			];
		});

		return [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Servers')),
				api.table([ '', _('Name'), _('URL'), _('Imported'), _('Selection'), _('Last sync'), '' ],
					rows, _('No links yet')),
				E('div', { 'class': 'cbi-page-actions' }, [
					api.button(_('Add link'), 'cbi-button-add', function() {
						return self.openAdd(refresh);
					}, self)
				])
			])
		];
	},

	openAdd: function(refresh) {
		var self = this;
		var name = api.input('', 'agent1');
		var url = api.input('', 'https://203.0.113.5:8447');
		var token = api.input('');
		var fp = api.input('', 'sha256//...');

		ui.showModal(_('Add link'), [
			E('p', {}, _('Run "sdx link add <router>" on the server; it prints the values below.')),
			api.field(_('Name'), name),
			api.field(_('URL'), url),
			api.field(_('Token'), token),
			api.field(_('Fingerprint'), fp),
			api.modalActions(_('Add'), function() {
				var n = name.value.trim();
				return api.run('', 'link', [ 'add', n, url.value.trim(),
					token.value.trim(), fp.value.trim() ]).then(function(out) {
					ui.hideModal();
					api.notify(out);
					return refresh().then(function() {
						return self.openConfigs({ name: n }, refresh);
					});
				}, api.fail);
			}, self)
		]);
	},

	openConfigs: function(link, refresh) {
		var self = this;
		ui.showModal(_('Configs from %s').format(link.name), [
			E('p', { 'class': 'spinning' }, _('Asking the server...'))
		]);
		return api.linkConfigs(link.name).then(function(res) {
			var boxes = [];
			var all = E('input', { 'type': 'checkbox' });
			all.checked = res.selected.indexOf('*') >= 0;

			var group = function(svc, list) {
				if (!list.length)
					return E('p', { 'class': 'cbi-value-description' }, api.labels[svc] + ': ' + _('none'));
				return E('div', {}, [ E('h4', {}, api.labels[svc]) ].concat(list.map(function(c) {
					var box = E('input', { 'type': 'checkbox', 'value': c.name });
					box.checked = all.checked || res.selected.indexOf(c.name) >= 0;
					boxes.push(box);
					return E('label', { 'style': 'display:block' }, [
						box, ' ', c.name, c.imported ? '' : E('em', {}, ' ' + _('(not imported)'))
					]);
				})));
			};

			var lists = E('div', {}, [ group('vpn', res.vpn), group('proxy', res.proxy) ]);
			all.addEventListener('change', function() {
				boxes.forEach(function(b) { b.disabled = all.checked; });
			});
			boxes.forEach(function(b) { b.disabled = all.checked; });

			ui.showModal(_('Configs from %s').format(link.name), [
				E('label', { 'style': 'display:block' }, [ all, ' ', _('Import everything the server offers') ]),
				lists,
				api.modalActions(_('Save'), function() {
					var args = [ 'select', link.name ];
					if (all.checked)
						args.push('--all');
					else
						boxes.filter(function(b) { return b.checked; }).forEach(function(b) {
							args.push(b.value);
						});
					return api.run('', 'link', args).then(function(out) {
						ui.hideModal();
						api.notify(out);
					}, api.fail).then(refresh);
				}, self)
			]);
		}, function(err) {
			ui.hideModal();
			api.fail(err);
		});
	}
});
