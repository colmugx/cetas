/**
 * Sidebar for a non-primary collection.
 *
 * Nimbus builds its filesystem sidebar from the primary `docs` collection, so a
 * translated collection (`en`, mounted at `/en`) would otherwise show the
 * default locale's tree with the wrong labels and links. This builds the same
 * shape from that collection's own entries: one level of directories become
 * groups, everything else stays a link, and ordering comes from each page's
 * `sidebar.order`.
 */
import type { SidebarItem } from "@cloudflare/nimbus-docs/types";
import { getIndexedEntries, stripBase } from "@cloudflare/nimbus-docs/runtime";

type Indexed = Awaited<ReturnType<typeof getIndexedEntries>>[number];

const formatLabel = (segment: string): string =>
  segment
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");

// `IndexedEntry.entry` is a union over every registered collection, so the
// sidebar metadata is only visible through a narrow structural type.
interface SidebarMeta {
  sidebar?: { order?: number; label?: string; hidden?: boolean };
}

const meta = (item: Indexed): SidebarMeta => item.entry.data as SidebarMeta;

const hasHiddenSidebar = (item: Indexed): boolean =>
  meta(item).sidebar?.hidden === true;

const orderOf = (item: Indexed): number =>
  meta(item).sidebar?.order ?? Number.MAX_VALUE;

const labelOf = (item: Indexed): string =>
  meta(item).sidebar?.label ?? item.title;

const slugOf = (item: Indexed): string =>
  stripBase(item.url, import.meta.env.BASE_URL).replace(/\/$/, "") || "/";

export async function sidebarForCollection(
  collection: string,
  currentSlug: string,
): Promise<SidebarItem[]> {
  const entries = (await getIndexedEntries()).filter(
    (item) => item.collection === collection && !hasHiddenSidebar(item),
  );

  const toLink = (item: Indexed): SidebarItem => ({
    type: "link",
    label: labelOf(item),
    // `getIndexedEntries().url` is already site-rooted (it carries the base),
    // so wrapping it again would double the prefix.
    href: item.url,
    isCurrent: currentSlug === slugOf(item),
    order: orderOf(item),
  });

  const leaves: SidebarItem[] = [];
  const grouped = new Map<string, Indexed[]>();

  for (const item of entries) {
    const segments = item.entry.id.split("/").filter(Boolean);
    if (segments.length <= 1) {
      leaves.push(toLink(item));
      continue;
    }
    const head = segments[0];
    grouped.set(head, [...(grouped.get(head) ?? []), item]);
  }

  const items: SidebarItem[] = [...leaves];

  for (const [segment, members] of grouped) {
    const children = members
      .map(toLink)
      .sort((a, b) => a.order - b.order);
    items.push({
      type: "group",
      label: formatLabel(segment),
      order: children.length > 0 ? children[0].order : Number.MAX_VALUE,
      children,
    });
  }

  return items.sort((a, b) => a.order - b.order);
}
