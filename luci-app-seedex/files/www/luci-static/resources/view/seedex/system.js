'use strict';
'require view';
'require ui';
'require seedex.api as api';

var SCOPES = [ [ '', _('All') ], [ 'vpn', 'VPN' ], [ 'proxy', 'Proxy' ], [ 'router', 'Router' ] ];

function readFile(file) {
	return new Promise(function(resolve, reject) {
		var reader = new FileReader();
		reader.onload = function() { resolve(reader.result); };
		reader.onerror = function() { reject(new Error(_('Cannot read %s').format(file.name))); };
		reader.readAsText(file);
	});
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	render: function() {
		return E('div', {}, [
			E('h2', {}, 'Seedex ' + _('System')),
			this.renderConfiguration(),
			this.renderLogs()
		]);
	},

	renderConfiguration: function() {
		var self = this;
		var scope = api.select('', SCOPES);
		var picker = E('input', { 'type': 'file', 'accept': '.conf,.json,text/plain,application/json' });

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Configuration')),
			api.field(_('Import config'), E('div', {}, [
				picker, ' ',
				api.button(_('Import'), 'cbi-button-action', function() {
					var file = picker.files && picker.files[0];
					if (!file)
						return Promise.resolve();
					return readFile(file).then(function(content) {
						return api.importConfig(file.name, content);
					}).then(function(out) {
						api.notify(out);
						picker.value = '';
					}, api.fail);
				}, self)
			]), _('An AmneziaWG .conf, a sing-box .json or a router rules .json; commit it on the service page')),
			api.field(_('Reset'), E('div', {}, [
				scope, ' ',
				api.button(_('Reset'), 'cbi-button-negative', function() {
					var label = scope.options[scope.selectedIndex].text;
					if (!confirm(_('Drop every entry and stored file for: %s?').format(label)))
						return Promise.resolve();
					return api.run(scope.value, 'reset').then(api.notify, api.fail);
				}, self)
			]), _('Stops the service and drops its entries and stored config files'))
		]);
	},

	renderLogs: function() {
		var self = this;
		var scope = api.select('', SCOPES);
		var out = E('pre', { 'style': 'max-height:30em; overflow:auto' }, '');

		var load = function() {
			return api.logs(scope.value).then(function(text) {
				out.textContent = text || _('(empty)');
			}, api.fail);
		};

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Logs')),
			E('div', {}, [ scope, ' ', api.button(_('Refresh'), 'cbi-button-action', load, self) ]),
			out
		]);
	}
});
