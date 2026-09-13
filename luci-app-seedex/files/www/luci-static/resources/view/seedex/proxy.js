'use strict';
'require seedex.configs as configs';

return configs.create({
	svc: 'proxy',
	ext: '.json',
	nameHint: _('Becomes the config name; the .json extension is added when missing'),
	placeholder: '{\n  "outbounds": [\n    { "type": "vless", "tag": "...", "server": "...", "server_port": 443 }\n  ]\n}',
	entrySettings: [],
	settings: [
		{ key: 'log_level', label: _('Log level'),
		  options: [ [ 'error' ], [ 'warn' ], [ 'info' ], [ 'debug' ], [ 'trace' ] ] },
		{ key: 'urltest_interval', label: _('URL test interval'), placeholder: '1m' }
	]
});
