package bootdev

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
)

var reNuxtData = regexp.MustCompile(`(?s)<script[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>`)

// PageData decodes the Nuxt payload in a page's HTML: the data the page was rendered from.
func PageData(html []byte) (map[string]any, error) {
	m := reNuxtData.FindSubmatch(html)
	if m == nil {
		return nil, errors.New("no page data found")
	}
	v, err := DecodeNuxt(m[1])
	if err != nil {
		return nil, fmt.Errorf("page data: %w", err)
	}
	root, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("page data is not an object")
	}
	return root, nil
}

// DecodeNuxt rebuilds the value graph of a Nuxt payload. The payload is a flat JSON array (the
// devalue format) in which objects and arrays point at other entries by index, and tagged
// arrays such as ["Reactive", 5] wrap a value. Numbers stay json.Number, so they stay exact.
func DecodeNuxt(raw []byte) (any, error) {
	var flat []any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&flat); err != nil {
		return nil, err
	}
	if len(flat) == 0 {
		return nil, errors.New("empty payload")
	}
	done := make(map[int]any)
	var at func(ref any) any
	at = func(ref any) any {
		n, ok := ref.(json.Number)
		if !ok {
			return nil
		}
		i, err := strconv.Atoi(n.String())
		if err != nil || i < 0 || i >= len(flat) {
			return nil // negative indexes stand for undefined, NaN and similar
		}
		if v, ok := done[i]; ok {
			return v
		}
		switch v := flat[i].(type) {
		case map[string]any:
			out := make(map[string]any, len(v))
			done[i] = out
			for k, r := range v {
				out[k] = at(r)
			}
			return out
		case []any:
			if len(v) > 0 {
				if tag, ok := v[0].(string); ok {
					out := untag(tag, v[1:], at)
					done[i] = out
					return out
				}
			}
			out := make([]any, len(v))
			done[i] = out
			for j, r := range v {
				out[j] = at(r)
			}
			return out
		default:
			done[i] = v
			return v
		}
	}
	return at(json.Number("0")), nil
}

func untag(tag string, args []any, at func(any) any) any {
	switch tag {
	case "Set":
		out := make([]any, len(args))
		for i, r := range args {
			out[i] = at(r)
		}
		return out
	case "Map", "null":
		out := make(map[string]any, len(args)/2)
		for i := 0; i+1 < len(args); i += 2 {
			k := args[i]
			if tag == "Map" {
				k = at(k)
			}
			out[fmt.Sprint(k)] = at(args[i+1])
		}
		return out
	case "Date", "RegExp", "BigInt", "Object":
		if len(args) > 0 {
			return args[0]
		}
	case "EmptyRef", "EmptyShallowRef":
		return nil
	default: // Nuxt's own wrappers: Reactive, ShallowReactive, Ref, ShallowRef, NuxtError
		if len(args) > 0 {
			return at(args[0])
		}
	}
	return nil
}
