# A nimbus node built from the current @unison/nimbus source on Unison Share.
#
# The newest published image (cloud_nimbus_releases_42_10_0_24676, 2025-11-19)
# is refused by today's control plane: its register message lacks `hostname`
# (unisoncomputing/byoc#2). This keeps that image's wrapper scripts and system
# packages, and replaces the two things that are out of date:
#
# - /usr/share/nimbus/nodeMain.uc: `main.nodeMain` compiled from Share.
# - /usr/lib/unisonweb/unison: the UCM that compiled it (a .uc runs only on the
#   UCM version that wrote it).
#
# The current source also requires a `clusterMap` config key that the
# template's configs lack. It only matters for Unison's own daemon node groups,
# so the wrapper's config merge now starts from an empty one; a config file
# that sets it still wins.
#
# Built by build.nu, which supplies nodeMain.uc, unison and version.txt.
FROM unisoncomputing/unison-cloud:cloud_nimbus_releases_42_10_0_24676

COPY unison /usr/lib/unisonweb/unison
COPY nodeMain.uc /usr/share/nimbus/nodeMain.uc
COPY version.txt /usr/share/nimbus/version.txt

RUN sed -i 's/({host: $defaultHost}; /({host: $defaultHost, clusterMap: {}}; /' /usr/local/bin/nimbus \
 && grep -q 'clusterMap: {}' /usr/local/bin/nimbus \
 && ucm --version
