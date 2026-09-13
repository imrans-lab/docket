# Typed query bindings

Legacy filters keep their literal column meaning. A registry-bound condition adds
the stable project-owned type identity and, for a custom field, its stable field
key:

```json
{"field_key":"score","type_id":"type:019...","op":"gte","value":0}
```

Type and status conditions use `field` with the same `type_id`. Derived fields
`state_category`, `state_outcome`, and `is_terminal` may omit `type_id` to query
all types; each row is then interpreted through its pinned `type_revision`.
Labels are presentation only and never bind a query. A missing type identity is
an error and must be rebound explicitly in the destination project.
Bound type identity predicates use `eq`; status predicates use `eq`, `neq`, or
`in`. Other operators are refused rather than approximated with a slug or a
positive identity filter.

Supported scalar operators are `eq`, `neq`, `in`, `is_empty`, `is_not_empty`,
`is_null`, and `is_missing`. Text fields additionally support `contains`, `not_contains`, and
`like`; numeric fields support `gt`, `gte`, `lt`, and `lte`; dates and timestamps
also support `before` and `after`. Operands must have the descriptor's type.
Arrays, objects, and reference lists currently support emptiness tests only.
`is_null` matches only an explicit JSON null and `is_missing` only an absent key;
`eq`/`neq` refuse a null operand so that distinction cannot be lost. `is_empty`
matches either case or an empty string. It does not match `false`, numeric zero,
an empty array, or an empty object.

Typed sorts use the same `field_key` and `type_id`, plus `dir` (`asc` or `desc`)
and `nulls` (`first` or `last`, default `last`). Rows whose pinned revision does not declare the
field sort as null. Multiple sort entries apply in order, followed by item ID as
the deterministic tie break.

An empty `$and` group matches every row and an empty `$or` group matches none.
This identity behavior is also used for generated constant branches. A node
that mixes `$and` and `$or`, or combines a boolean operator with leaf keys, is
invalid.

Saved project queries and `.dcq` files persist these dictionaries verbatim,
including every filter and sort identity. Loading never substitutes a same-slug
type from another project. Copying a query to another project therefore requires
an explicit destination binding for every absent type identity. Use
`docket_type_get` in the destination to obtain its stable ID, then replace the
saved condition/sort `type_id` deliberately (after defining or importing the
required meaning); loading never performs that substitution.
