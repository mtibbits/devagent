-- scripts/docs-site/links.lua — pandoc Lua filter for build-docs-site.sh (#465).
--
-- docs-site/*.md link to each other as ./<page>.md so they read correctly on the
-- forge. On the published site those targets must be <page>.html, and a link
-- that climbs out of docs-site/ (../README.md#...) has no published twin, so it
-- goes to the forge's rendered copy instead.
--
-- Every link is CLASSIFIED; a target that fits no class is a build error, not
-- a pass-through. A silently-preserved ./foo/bar.md would publish a 404.
--
--   scheme:...   (https:, mailto:)   unchanged
--   #fragment                        unchanged
--   ./<page>.md[#frag]               <page>.html[#frag]
--   ../<path>[#frag]                 <blob_base><path>[#frag]
--   anything else                    error

local blob_base = nil

function Meta(meta)
  if meta.blob_base then
    blob_base = pandoc.utils.stringify(meta.blob_base)
  end
  return nil
end

local function rewrite(el)
  local t = el.target
  if t:match("^%a[%w+.-]*:") or t:match("^#") then
    return el
  end
  local up = t:match("^%.%./(.+)$")
  if up then
    if not blob_base or blob_base == "" then
      error("build-docs-site: link leaves docs-site/ but no blob_base was given: " .. t)
    end
    el.target = blob_base .. up
    return el
  end
  local page, frag = t:match("^%./([%w_-]+)%.md(.*)$")
  if page and (frag == "" or frag:match("^#")) then
    el.target = page .. ".html" .. frag
    return el
  end
  error("build-docs-site: unclassified link target: " .. t)
end

-- Meta must run before Link so blob_base is known; pandoc's default order
-- visits inlines first, so force two passes.
return {
  { Meta = Meta },
  { Link = rewrite },
}
