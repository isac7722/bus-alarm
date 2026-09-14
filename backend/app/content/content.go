// Package content contains policy content also consumed by the iOS project.
package content

import (
	_ "embed"
	"encoding/json"
	"strings"
	"sync"
)

//go:embed privacy.json
var policyJSON []byte

//go:embed privacy.html
var page string
var renderOnce = sync.OnceValues(render)

func RenderPrivacy() (string, error) { return renderOnce() }
func render() (string, error) {
	var policy struct {
		Title         string
		EffectiveDate string
		ContactEmail  string
		Sections      []struct {
			Title      string
			Paragraphs []string
		}
	}
	if err := json.Unmarshal(policyJSON, &policy); err != nil {
		return "", err
	}
	escape := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;", "'", "&#x27;").Replace
	sections := []string{}
	for _, s := range policy.Sections {
		section := "<section><h2>" + escape(s.Title) + "</h2>"
		for _, p := range s.Paragraphs {
			section += "<p>" + escape(p) + "</p>"
		}
		sections = append(sections, section+"</section>")
	}
	return strings.NewReplacer("{{title}}", escape(policy.Title), "{{date}}", escape(policy.EffectiveDate), "{{email}}", escape(policy.ContactEmail), "{{sections}}", strings.Join(sections, "\n")).Replace(page), nil
}
