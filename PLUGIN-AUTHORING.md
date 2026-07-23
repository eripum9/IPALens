# Creating an IPALens Plugin

IPALens plugins are signed, data-only platform definitions. They extend package recognition and inspection layouts without loading executable plugin code.

## Required package contents

An `.ipalensplugin` file is a ZIP archive whose root should contain:

- `Plugin.json` — the versioned plugin manifest. This file is required.
- `README.md` — the full user-facing description shown on the plugin’s Overview page. Plugin makers are required to provide this for a complete storefront listing. Older or local packages without it remain inspectable, but IPALens displays **“No description was provided.”**

The catalog entry and `Plugin.json` must also provide a concise `description`. This is the short summary shown below the plugin on the storefront homepage; it is not a replacement for `README.md`.

Optional artwork and documentation resources may use the existing allowlisted JSON, plist, Markdown, PNG, and ICNS formats. Scripts, native binaries, symlinks, and other executable resources are rejected.

## Storefront identity

Each plugin must clearly declare:

- `name` — the customer-facing plugin name;
- `publisher` — the maker displayed on its detail page;
- the catalog source — displayed by IPALens as the provider;
- `version`, `hostAPIVersion`, capabilities, artifact size, SHA-256, and signature.

Keep the catalog description brief. Put setup instructions, supported formats, limitations, privacy details, and release notes in `README.md`.

## Permissions and command disclosure

IPALens generates the Permissions page itself. Plugin packages cannot provide or hide their own permission list.

The scanner reports:

- user-selected file and folder access used by the IPALens host;
- declared application-bundle, archive, disk-image, and installer-package capabilities;
- fixed host utilities implied by a capability, such as `/usr/bin/hdiutil` and `/usr/sbin/pkgutil`;
- recognized system-command references found statically in plugin JSON, plist, and Markdown resources;
- network access used by IPALens to contact the approved catalog provider for downloads and updates.

These disclosures describe host-controlled behavior, not direct macOS permission grants. A data-only plugin cannot execute a command or access a file by itself.

## Packaging rules

- Use normalized relative paths only; traversal, absolute, duplicate-normalized, backslash, NUL, and symlink paths are rejected.
- Keep the archive below 50 MiB, each resource below 10 MiB, and `Plugin.json` below 1 MiB.
- Include at most 1,000 entries.
- Use HTTPS artifact and catalog URLs without credentials, redirects to private networks, or mutable release URLs.
- Sign official and third-party artifacts and catalogs with Ed25519. Never distribute the private signing key.
- Match the manifest ID, version, publisher, and host API to the signed catalog entry.

IPALens scans every package before installation and installs it atomically. An invalid update never replaces the working version.
