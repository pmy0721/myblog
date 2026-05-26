# Remote sync inventory

Generated on 2026-05-26 from `root@120.26.23.38:/var/www/html/`.

## Likely Hugo output

- `404.html`
- `algolia.json`
- `archives/`
- `assets/`
- `categories/`
- `css/`
- `images/`
- `img/`
- `index.html`
- `index.xml`
- `js/`
- `moments/`
- `page/`
- `post/`
- `posts/`
- `sitemap.xml`
- `tags/`
- `uploads/`
- `webfonts/`

## Likely non-Hugo or manually preserved

- `_backup_removed_posts_20260518-224501/`
- `app/`
- `motion-fruit-ninja/`
- `webapp/`
- `index.nginx-debian.html`

## Sync recommendation

Use the existing `scp` deploy for now because it does not delete remote-only
directories. Before switching to `rsync --delete`, either move non-Hugo apps out
of `/var/www/html/` or use explicit exclusions for the manually preserved paths.
