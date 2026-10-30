# Bookshelf Hybrid Shelf (`bookshelf-hybrid.koplugin`)

A KOReader plugin that provides a unified Hybrid shelf source for the Bookshelf plugin, merging local storage and remote Komga libraries into a single cohesive browsing and reading interface.

## My Use Case

I use KOReader on an e-reader device to read Manga and Light Novels hosted on my home Komga server. To read away from home, I frequently auto-download chapters and volumes to local storage using Kokomga.

Before creating this plugin, my reading workflow had several friction points:
- Local downloads and remote Komga libraries lived in separate views, resulting in duplicate entries and disconnected series.
- Kokomga auto-downloaded files were not recognized as matching the remote library entries on the shelf.
- Offline navigation was unreliable: navigating into a remote series without an active connection would often block or return empty lists.
- Reading status synchronization lagged: after finishing a downloaded book, the shelf would not reflect that the book was completed until the remote server was synced and refreshed.

I built this plugin to solve those issues by adding a dedicated "Hybrid" source to Bookshelf. It cross-references local files against remote Komga entries using Kokomga's internal download mappings and title normalization, caches series structures for instant offline drill-down, and inspects local sidecar settings so finished books immediately register as completed.

## General Use Case

The Hybrid Shelf plugin extends KOReader's Bookshelf plugin with a consolidated view that blends local directories with remote OPDS/Komga libraries.

Key features include:
- Single unified view for local storage and remote server libraries.
- Intelligent deduplication that pairs local files with remote catalog items.
- Full integration with Kokomga auto-downloads via internal ID mapping.
- Offline-resilient caching with automatic background refresh when online.
- Authoritative local progress tracking derived from KOReader sidecar settings.
- Fast-fail network guards to prevent UI hangs when the server is unreachable.

## Dependencies

- [KOReader](https://github.com/koreader/koreader): Document viewer for e-ink devices and Android.
- [Bookshelf](https://github.com/koreader/koreader): Visual bookshelf plugin for KOReader.

### Recommended Integrations

- [Kokomga](https://github.com/zenf/kokomga): Komga client plugin for KOReader handling remote syncing and automated downloads.
- [kokomga-bookshelf-bridge.koplugin](https://github.com/oauei/kokomga-bookshelf-bridge.koplugin): Bridges credentials, profiles, cover caches, and health checks between Kokomga and Bookshelf.

## Installation

Clone this repository into your KOReader plugins directory:

```bash
cd <koreader-directory>/plugins/
git clone https://github.com/oauei/bookshelf-hybrid.koplugin.git
```

Restart KOReader, open Bookshelf settings, and select "Hybrid" as your shelf source.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
