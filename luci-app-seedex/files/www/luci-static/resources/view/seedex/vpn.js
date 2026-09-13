'use strict';
'require seedex.configs as configs';

return configs.create({
	svc: 'vpn',
	ext: '.conf',
	nameHint: _('Becomes the config name; the .conf extension is added when missing'),
	placeholder: '[Interface]\nPrivateKey = ...\nAddress = 10.66.67.2/32\n\n[Peer]\nPublicKey = ...\nEndpoint = host:51821',
	entrySettings: [],
	settings: []
});
