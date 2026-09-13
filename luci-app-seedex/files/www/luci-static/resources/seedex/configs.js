'use strict';
'require baseclass';
'require view';
'require ui';
'require poll';
'require dom';
'require seedex.api as api';

return baseclass.extend({
	create: function(opts) {
		var svc = opts.svc;
		var entrySettings = opts.entrySettings || [];

		return view.extend({
			handleSave: null,
			handleSaveApply: null,
			handleReset: null,

			load: function() {
				return Promise.all([ api.status(), api.config(svc) ]);
			},

			refresh: function() {
				var self = this;
				return Promise.all([ api.status(), api.config(svc) ]).then(function(r) {
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
					E('h2', {}, 'Seedex ' + api.labels[svc]),
					this.body
				]);
			},

			renderBody: function() {
				var refresh = L.bind(this.refresh, this);
				return [
					api.serviceHeader(svc, this.status, refresh, this),
					api.pendingBanner(svc, this.status, refresh, this),
					this.renderConfigs(refresh),
					opts.settings.length ? api.settingsCard(svc, opts.settings, this.values, refresh, this) : ''
				];
			},

			entryName: function(s) {
				return s.name || s['.name'];
			},

			renderConfigs: function(refresh) {
				var self = this;
				var rows = api.sections(self.values, 'config').map(function(s) {
					var name = self.entryName(s);
					var enabled = s.enabled == '1';
					var cells = [ api.mark(enabled), name ];
					entrySettings.forEach(function(k) {
						cells.push(s[k.key] || '—');
					});
					cells.push((s.config || '').split('/').pop() || '—');
					cells.push(E('div', {}, [
						api.button(_('Edit'), 'cbi-button-action', function() {
							return self.openEditor(s, refresh);
						}, self),
						' ',
						api.button(enabled ? _('Disable') : _('Enable'), 'cbi-button-neutral', function() {
							return api.run(svc, enabled ? 'disable' : 'enable', [ name ])
								.catch(api.fail).then(refresh);
						}, self),
						' ',
						api.button(_('Remove'), 'cbi-button-remove', function() {
							if (!confirm(_('Remove config "%s"?').format(name)))
								return Promise.resolve();
							return api.run(svc, 'remove', [ name ]).catch(api.fail).then(refresh);
						}, self)
					]));
					return cells;
				});

				var titles = [ '', _('Name') ].concat(entrySettings.map(function(k) {
					return k.label;
				}), [ _('File'), '' ]);

				return E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Configs')),
					api.table(titles, rows, _('No configs yet')),
					E('div', { 'class': 'cbi-page-actions' }, [
						api.button(_('Add config'), 'cbi-button-add', function() {
							return self.openCreator(refresh);
						}, self)
					])
				]);
			},

			openCreator: function(refresh) {
				var self = this;
				var name = api.input('', 'my-server' + opts.ext);
				var content = api.textarea('', 16, opts.placeholder);

				ui.showModal(_('Add %s config').format(api.labels[svc]), [
					api.field(_('File name'), name, opts.nameHint),
					api.field(_('Contents'), content),
					api.modalActions(_('Import'), function() {
						var n = name.value.trim();
						if (n && n.indexOf('.') < 0)
							n += opts.ext;
						return api.importConfig(n, content.value).then(function(out) {
							ui.hideModal();
							api.notify(out);
						}, api.fail).then(refresh);
					}, self)
				]);
			},

			openEditor: function(s, refresh) {
				var self = this;
				var name = self.entryName(s);

				return api.file(svc, s.config || '').then(function(file) {
					var content = api.textarea(file.content, 16);
					var inputs = {};
					var note = file.missing ? _('Config file is missing') : '';

					var fields = entrySettings.map(function(k) {
						inputs[k.key] = api.input(s[k.key], k.placeholder);
						return api.field(k.label, inputs[k.key], k.hint);
					});

					ui.showModal(name, fields.concat([
						api.field(_('Contents'), content, note),
						api.modalActions(_('Save'), function() {
							var settings = entrySettings.map(function(k) {
								return k.key + '=' + inputs[k.key].value.trim();
							}).filter(function(kv) {
								return kv.split('=')[1] !== '';
							});
							var changedSettings = entrySettings.some(function(k) {
								return inputs[k.key].value.trim() !== (s[k.key] || '');
							});
							var task;

							if (content.value !== file.content) {
								var base = (s.config || '').split('/').pop();
								task = api.run(svc, 'remove', [ name ]).then(function() {
									return api.importConfig(base, content.value);
								}).then(function(out) {
									api.notify(out);
									if (settings.length)
										return api.run(svc, 'update', [ name ].concat(settings));
								});
							}
							else if (changedSettings && settings.length) {
								task = api.run(svc, 'update', [ name ].concat(settings));
							}
							else {
								task = Promise.resolve();
							}

							return task.then(ui.hideModal, api.fail).then(refresh);
						}, self)
					]));
				}, api.fail);
			}
		});
	}
});
