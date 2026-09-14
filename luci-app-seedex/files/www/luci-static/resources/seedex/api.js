'use strict';
'require baseclass';
'require rpc';
'require ui';

var callStatus = rpc.declare({
	object: 'luci.seedex',
	method: 'status',
	reject: true
});

var callRun = rpc.declare({
	object: 'luci.seedex',
	method: 'run',
	params: [ 'svc', 'action', 'args', 'stdin' ],
	reject: true
});

var callImport = rpc.declare({
	object: 'luci.seedex',
	method: 'import',
	params: [ 'name', 'content' ],
	reject: true
});

var callConfig = rpc.declare({
	object: 'luci.seedex',
	method: 'config',
	params: [ 'svc' ],
	reject: true
});

var callFile = rpc.declare({
	object: 'luci.seedex',
	method: 'file',
	params: [ 'svc', 'path' ],
	reject: true
});

var callLogs = rpc.declare({
	object: 'luci.seedex',
	method: 'logs',
	params: [ 'svc' ],
	reject: true
});

function unwrap(res) {
	if (!res || res.code !== 0)
		throw new Error((res && (res.error || res.output)) || _('Command failed'));
	return res.output;
}

return baseclass.extend({
	labels: { vpn: 'VPN', proxy: 'Proxy', router: 'Router', dns: 'DNS' },

	status: callStatus,

	file: callFile,

	logs: function(svc) {
		return callLogs(svc || '').then(unwrap);
	},

	run: function(svc, action, args, stdin) {
		return callRun(svc || '', action, args || [], stdin || '').then(unwrap);
	},

	importConfig: function(name, content) {
		return callImport(name, content).then(unwrap);
	},

	config: function(svc) {
		return callConfig(svc).then(function(res) {
			return (res && res.values) || {};
		});
	},

	sections: function(values, type) {
		return Object.keys(values).map(function(sid) {
			return values[sid];
		}).filter(function(s) {
			return s['.type'] == type;
		}).sort(function(a, b) {
			return (a['.index'] || 0) - (b['.index'] || 0);
		});
	},

	notify: function(msg, kind) {
		ui.addNotification(null, E('p', {}, msg), kind || 'info');
	},

	fail: function(err) {
		ui.addNotification(null, E('pre', {}, String((err && err.message) || err)), 'error');
	},

	mark: function(on) {
		return on ? '[*]' : '[ ]';
	},

	running: function(status, svc) {
		return !!(status.running && status.running[svc]);
	},

	button: function(label, cls, fn, ctx) {
		return E('button', {
			'class': 'btn cbi-button ' + (cls || ''),
			'click': ui.createHandlerFn(ctx || this, fn)
		}, label);
	},

	field: function(label, widget, hint) {
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, label),
			E('div', { 'class': 'cbi-value-field' }, [
				widget,
				hint ? E('div', { 'class': 'cbi-value-description' }, hint) : ''
			])
		]);
	},

	input: function(value, placeholder) {
		return E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'value': value == null ? '' : value,
			'placeholder': placeholder || ''
		});
	},

	select: function(value, options) {
		var sel = E('select', { 'class': 'cbi-input-select' }, options.map(function(o) {
			return E('option', { 'value': o[0] }, o[1] || o[0]);
		}));
		sel.value = value;
		return sel;
	},

	textarea: function(value, rows, placeholder) {
		return E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%; font-family:monospace',
			'rows': rows || 12,
			'placeholder': placeholder || ''
		}, value || '');
	},

	modalActions: function(saveLabel, fn, ctx) {
		return E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-positive important',
				'click': ui.createHandlerFn(ctx || this, fn)
			}, saveLabel)
		]);
	},

	table: function(titles, rows, empty) {
		if (!rows.length)
			return E('p', { 'class': 'cbi-value-description' }, empty || _('None'));
		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, titles.map(function(t) {
				return E('th', { 'class': 'th' }, t);
			}))
		].concat(rows.map(function(cells) {
			return E('tr', { 'class': 'tr' }, cells.map(function(c) {
				return E('td', { 'class': 'td' }, c);
			}));
		})));
	},

	serviceHeader: function(svc, status, refresh, ctx) {
		var self = this;
		var running = this.running(status, svc);
		var act = function(action) {
			return function() {
				return self.run(svc, action).catch(self.fail).then(refresh);
			};
		};
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, self.mark(running) + ' ' + self.labels[svc] + ': ' +
				(running ? _('running') : _('stopped'))),
			E('div', {}, [
				self.button(running ? _('Stop') : _('Start'), 'cbi-button-action',
					act(running ? 'stop' : 'start'), ctx),
				' ',
				self.button(_('Restart'), 'cbi-button-action', act('restart'), ctx)
			])
		]);
	},

	pendingBanner: function(svc, status, refresh, ctx) {
		var self = this;
		var lines = (status.pending || {})[svc] || [];
		var stale = !!(status.stale && status.stale[svc]);
		if (!lines.length && !stale)
			return '';
		var act = function(action) {
			return function() {
				return self.run(svc, action).catch(self.fail).then(refresh);
			};
		};
		var parts = [];
		if (lines.length)
			parts.push(E('h4', {}, _('Pending changes')), E('pre', {}, lines.join('\n')));
		else
			parts.push(E('h4', {}, _('Changes not applied yet')));
		parts.push(E('p', {}, _('A restart applies them; commit keeps them across reboots.')));
		parts.push(self.button(_('Restart'), 'cbi-button-action', act('restart'), ctx));
		if (lines.length)
			parts.push(' ', self.button(_('Commit'), 'cbi-button-positive', act('commit'), ctx),
				' ', self.button(_('Revert'), 'cbi-button-negative', act('revert'), ctx));
		return E('div', { 'class': 'alert-message warning' }, parts);
	},

	settingsCard: function(svc, keys, values, refresh, ctx) {
		var self = this;
		var main = values.main || {};
		var inputs = {};

		var rows = keys.map(function(k) {
			var current = main[k.key];
			inputs[k.key] = k.options ? self.select(current || '', k.options)
			                          : self.input(current, k.placeholder);
			inputs[k.key].setAttribute('data-current', current || '');
			return self.field(k.label || k.key, inputs[k.key], k.hint);
		});

		var save = function() {
			var args = [ 'set' ];
			keys.forEach(function(k) {
				var el = inputs[k.key], v = el.value.trim();
				if (v !== '' && v !== el.getAttribute('data-current'))
					args.push(k.key + '=' + v);
			});
			if (args.length < 2)
				return Promise.resolve();
			return self.run(svc, 'config', args).catch(self.fail).then(refresh);
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('%s settings').format(self.labels[svc])),
			E('div', {}, rows),
			E('div', { 'class': 'cbi-page-actions' }, [
				self.button(_('Save'), 'cbi-button-save', save, ctx)
			])
		]);
	}
});
