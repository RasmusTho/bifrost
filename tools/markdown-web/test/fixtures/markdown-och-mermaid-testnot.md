---
uuid: 7d3f2a9e-4c1b-4e8a-9f6d-2b5c8e1a0f47
origin: uat-walkthrough
title: Markdown och Mermaid – testnot
tags: [uat, bifrost, rendering]
created: 2026-10-14
---

# Markdown och Mermaid – testnot

A render test for Mimer (Bifrost) and Obsidian. Every section below exercises one feature, so it is easy to see what renders, what degrades, and what breaks. Swedish characters for font coverage: **å ä ö Å Ä Ö**, and typographic marks: “quotes”, ‘single’, en–dash, em—dash, ellipsis…

## 1. Headings

### Heading level 3
#### Heading level 4
##### Heading level 5
###### Heading level 6

## 2. Inline formatting

Plain text with **bold**, *italic*, ***bold italic***, ~~strikethrough~~, ==highlight==, `inline code`, and a [regular link](https://obsidian.md). Obsidian wikilinks: [[fixture]], [[source|aliased link]], and a heading link [[#4. Lists]]. Tags: #uat #bifrost/rendering. A footnote reference[^1] and an inline footnote.^[Inline footnotes are an Obsidian extension.]

Line one ends with two spaces  
so this is a hard line break inside the same paragraph.

## 3. Block quotes and callouts

> A plain block quote.
> > A nested quote inside it.

> [!note] Note callout
> Callouts are Obsidian-flavoured block quotes with a type.

> [!warning] Warning callout
> Should render with the amber / staged meaning in Yggdrasil.

> [!tip]- Collapsed tip (foldable)
> Hidden until expanded in Obsidian.

## 4. Lists

- Unordered item
- Item with **formatting** and `code`
  - Nested item
    - Third level
- Back to level one

1. Ordered item
2. Second item
   1. Nested ordered
   2. Another
3. Third item

- [ ] Open task
- [x] Completed task
- [ ] Task with a date 📅 2026-10-20

## 5. Table

| Theme | Surface | Ink contrast | Notes |
|:------|:-------:|-------------:|-------|
| Yggdrasil Dark | `#070B12` | 15.81 | Default |
| Yggdrasil Light “Shell” | porcelain | 4.63–8.83 | Ghost in the Shell |
| System | follows device | — | Shell in light mode |

## 6. Code

```swift
enum YggAppearance: String, CaseIterable {
    case dark, shell, system
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .shell: .light
        case .system: nil
        }
    }
}
```

```python
def resolve(theme: str | None) -> str:
    return theme if theme in {"dark", "light", "system"} else "dark"
```

```json
{ "theme": "shell", "density": "comfortable" }
```

## 7. Math

Inline math: $E = mc^2$. Block math:

$$
\sum_{i=1}^{n} i = \frac{n(n+1)}{2}
$$

## 8. Horizontal rule

---

## 9. Mermaid diagrams

### 9.1 Flowchart

```mermaid
flowchart LR
    Capture[Heimdal capture] --> Outbox[(Transfer outbox)]
    Outbox -->|receipt| Vault[(Obsidian vault)]
    Vault --> Mimer[Mimer lenses]
    Mimer -->|annotate| WriteGuard{WriteGuard}
    WriteGuard -->|approved| Vault
    WriteGuard -->|rejected| Mimer
```

### 9.2 Sequence diagram

```mermaid
sequenceDiagram
    actor Rasmus
    participant iPad as Mimer (iPad)
    participant Vault as Vault (iCloud)
    Rasmus->>iPad: Open note
    iPad->>Vault: read(path)
    Vault-->>iPad: markdown + frontmatter
    Rasmus->>iPad: Annotate
    iPad->>Vault: readModifyWrite(append)
    Vault-->>iPad: provenance receipt
```

### 9.3 State diagram

```mermaid
stateDiagram-v2
    [*] --> Draft
    Draft --> Proposed: agent suggests
    Proposed --> Canonical: human confirms
    Proposed --> Draft: human rejects
    Canonical --> Deprecated
    Deprecated --> [*]
```

### 9.4 Class diagram

```mermaid
classDiagram
    class YggTheme {
        +Color background
        +Color accent
        +role(dark, shell) Color
    }
    class YggAppearance {
        <<enumeration>>
        dark
        shell
        system
    }
    YggAppearance --> YggTheme : selects
```

### 9.5 Entity relationship

```mermaid
erDiagram
    NOTE ||--o{ ANNOTATION : has
    NOTE ||--|| FRONTMATTER : carries
    ANNOTATION }o--|| AGENT : "written by"
```

### 9.6 Gantt

```mermaid
gantt
    title Bifrost design-system rollout
    dateFormat YYYY-MM-DD
    section Tokens
    Re-vendor 2.2.1      :done,    t1, 2026-10-14, 1d
    section Shell
    Translucent surfaces :done,    s1, 2026-10-14, 1d
    Bundled fonts        :active,  s2, 2026-10-14, 1d
    Device UAT           :         s3, after s2, 2d
```

### 9.7 Pie chart

```mermaid
pie title Where reading time goes
    "Reading" : 55
    "Annotating" : 25
    "Navigating" : 20
```

### 9.8 Mindmap

```mermaid
mindmap
  root((Yggdrasil))
    Heimdal
      Capture
      Consent
    Mimer
      Lenses
      Canvas
    Hugin
    Munin
```

## 10. Embeds and HTML

![[fixture]]

<details>
<summary>Raw HTML details block</summary>

Content inside an HTML `<details>` element.

</details>

## 11. Long content

A deliberately long paragraph to test line length, wrapping and reading comfort on the porcelain reading surface. Lorem ipsum is avoided on purpose: this sentence keeps going so that the line wraps several times across the column, and the rhythm of the body face (Space Grotesk) can be judged next to the headings and the monospaced code blocks above it.

[^1]: A standard Markdown footnote, rendered at the end of the note.
