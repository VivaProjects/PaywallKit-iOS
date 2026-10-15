"""Generate this SDK repository's schema, catalog and bundled resources."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def obj(properties, required=None):
    return {"type": "object", "properties": properties,
            "required": list(properties) if required is None else required,
            "additionalProperties": False}


def enum(*values):
    return {"type": "string", "enum": list(values)}


def array(items, maximum=12):
    return {"type": "array", "items": items, "minItems": 1, "maxItems": maximum}


TEXT = {"type": "string", "minLength": 1, "maxLength": 2000}
ID = {"type": "string", "minLength": 1, "maxLength": 80,
      "pattern": "^[A-Za-z0-9_.-]+$"}
SPACING = {"type": "integer", "enum": [0, 4, 8, 12, 16, 20, 24, 32, 40, 48]}
PROPS = {
    "paywallScreen": obj({"backgroundToken": enum("surface")}),
    "hero": obj({"assetId": ID, "altKey": ID, "aspectRatio": {
        "type": "number", "minimum": 0.5, "maximum": 3}}),
    "heading": obj({"textKey": ID, "typography": enum("titleXL", "bodyM", "caption"),
                    "alignment": enum("leading", "center")}),
    "benefitList": obj({"itemsKey": ID}),
    "productPicker": obj({"catalogKey": ID, "selection": enum("recommended", "first")}),
    "informationSection": obj({"titleKey": ID, "bodyKey": ID, "collapsible": {"type": "boolean"}}),
    "legalActions": obj({"showRestore": {"const": True}}),
    "spacer": obj({"spacingToken": enum("pageX", "section", "itemGap")}),
    "purchaseBar": obj({"titleKey": ID, "action": obj({"type": enum("purchaseSelected")})}),
    "closeButton": obj({"labelKey": ID, "action": obj({"type": enum("dismiss"),
                                                       "reason": enum("userClose")})}),
}
CAPABILITIES = {name: f"{name}.v1" for name in PROPS}
CAPABILITIES.update(productPicker="product_picker.v1", purchaseBar="purchase_bar.v1")


def node(name):
    props = {"type": {"const": name}, "nodeId": ID, "props": PROPS[name]}
    if name == "paywallScreen":
        props["children"] = array({"anyOf": [{"$ref": f"#/$defs/{n}"} for n in PROPS
                                           if n not in ("paywallScreen", "purchaseBar")]})
    return obj(props)


def write(path, value):
    dest = ROOT / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    # Document structure is independent of the host distribution transport.
    strings = {"type": "object", "minProperties": 1, "additionalProperties": TEXT}
    lists = {"type": "object", "additionalProperties": array(TEXT)}
    locale = obj({"strings": strings, "lists": lists})
    schema = obj({
        "documentId": ID, "revision": {"type": "integer", "minimum": 1, "maximum": 2147483647},
        "schemaVersion": {"const": "1.0"},
        "minimumRendererVersion": obj({p: {"type": "integer", "minimum": 1, "maximum": 2147483647}
                                       for p in ("ios", "flutter")}),
        "requiredCapabilities": {**array(enum(*CAPABILITIES.values())), "uniqueItems": True},
        "placement": ID,
        "localization": obj({"defaultLocale": ID, "locales": {
            "type": "object", "minProperties": 1, "maxProperties": 12, "additionalProperties": locale}}),
        "tokens": obj({"color": obj({"accent": enum("interactiveBlue", "interactiveGreen"),
                                    "surface": enum("paywallSurface")}),
                       "spacing": obj({k: SPACING for k in ("pageX", "section", "itemGap")}),
                       "shape": obj({"card": enum("radius16", "radius26"), "cta": enum("capsule")})}),
        "tree": {"$ref": "#/$defs/paywallScreen"},
        "bottomBar": {"$ref": "#/$defs/purchaseBar"},
        "tracking": obj({"surface": {"const": "paywall"}, "variant": ID}),
    })
    schema.update({"$schema": "https://json-schema.org/draft/2020-12/schema",
                   "$id": "urn:paywall:document:1.0", "$defs": {n: node(n) for n in PROPS}})
    catalog = {"schemaVersion": "1.0", "rendererVersion": 1,
               "components": [{"type": n, "capability": CAPABILITIES[n], "props": p} for n, p in PROPS.items()]}
    write("protocol/paywall.schema.json", schema)
    write("protocol/component-catalog.json", catalog)
    for path in ("Sources/PaywallKit/Resources/paywall.schema.json",):
        write(path, schema)
    for path in ("Sources/PaywallKit/Resources/component-catalog.json",):
        write(path, catalog)


if __name__ == "__main__":
    main()
