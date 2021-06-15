dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()

local item_name_newline = os.getenv("item_name_newline")
local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false


discovered_items = {}
local last_main_site_time = 0
local current_item_type = nil
local current_item_value = nil

local callbackIndex = 0
local callbackOriginParmas = {}
local callbackOriginatingPages = {}

io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

do_debug = true
print_debug = function(a)
  if do_debug then
    print(a)
  end
end
print_debug("This grab script is running in debug mode. You should not see this in production.")

set_new_item = function(url)

  local wiki = string.match(url, "^https?://([^%./]+)%.wikidot%.com/") or string.match(url, "^https?://([^%./]+)%.wikidot%.com$")
  if wiki then
    current_item_type = "wiki"
    current_item_value = wiki
    return
  end
end

discover_item = function(item_type, item_name)
  assert(item_type)
  assert(item_name)
  if not discovered_items[item_type .. ":" .. item_name] then
    print_debug("Queuing for discovery " .. item_type .. ":" .. item_name)
  end
  discovered_items[item_type .. ":" .. item_name] = true
end

add_ignore = function(url)
  if url == nil then -- For recursion
    return
  end
  if downloaded[url] ~= true then
    downloaded[url] = true
  else
    return
  end
  add_ignore(string.gsub(url, "^https", "http", 1))
  add_ignore(string.gsub(url, "^http:", "https:", 1))
  local nothing_after_domain = string.match(url, "^([^%?#]+[^/])$")
  if nothing_after_domain then
    add_ignore(nothing_after_domain .. "/")
  end
  add_ignore(string.match(url, "^(.+)/$"))
end

for ignore in io.open("ignore-list", "r"):lines() do
  add_ignore(ignore)
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

is_on_targeted = function(url)
  return string.match(url, "^https?://[^/%.]+%.wikidot%.com/") or string.match(url, "^https?://[^/%.]+%.wikidot%.com$")
end

allowed = function(url, parenturl)
  assert(parenturl ~= nil)

  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end

  -- 3rd party sites, unnecess
  if string.match(url, "^https?://[^/]%.nitropay%.com/") then
    return false
  end
  
  -- Share buttons
  if string.match(url, "^https?://twitter%.com/home%?status")
    or string.match(url, "^https?://www%.facebook%.com/share")
    or string.match(url, "^https?://delicious%.com/save")
    or string.match(url, "^https?://digg%.com/submit")
    or string.match(url, "^https?://www%.reddit%.com/submit")
    or string.match(url, "^https?://www%.stumbleupon%.com/submit")
    or string.match(url, "^https?://mix%.com/mixit") then
    return false
  end
  
  local user = string.match(url, "^https?://www%.wikidot%.com/user:info/(.*)")
  if user then
    discover_item("user", user)
    return false
  end
  
  local wiki = string.match(url, "^https?://([^%./]+)%.wikidot%.com/") or string.match(url, "^https?://([^%./]+)%.wikidot%.com$")
  if wiki and wiki ~= current_item_value then
    discover_item("wiki", wiki)
    return false
  end
  
  -- THumbnails
  if string.match(url, "^https?://[^/]+%.wdfiles%.com/") then
    return true
  end

  if not is_on_targeted(url) then
    --print("Discarding 3p site " .. url .. "; stop the project if you see this in production") -- TODO decide what do do with these
    return false
  end
  
  -- This is retrieved, but only through POST
  -- This will also match relative URLs erroneously extracted from responses from this endpoint
  if string.match(url, "/ajax%-module%-connector%.php") then
    return false
  end
  
  if string.match(url, "^https?://([^%./]+)%.wikidot%.com/forum:new%-thread/") then
    return false
  end
  

  --print_debug("Allowed true on " .. url)
  return true

  --assert(false, "This segment should not be reachable")
end


wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  --print_debug("DCP on " .. url)
  if downloaded[url] == true or addedtolist[url] == true then
    return false
  end
  if allowed(url, parent["url"]) then
    addedtolist[url] = true
    --set_derived_url(url)
    return true
  end

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  local function absolute(url, newurl)
    if string.match(url, "^https?://api%-reader%.tinkercad%.com/users/([^/%?#%-]+)$") then
      return urlparse.absolute(url, "/api" .. newurl)
    else
      return urlparse.absolute(url, newurl)
    end
  end

  local function check(urla, force)
    assert(not force or force == true) -- Don't accidentally put something else for force
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    -- url_ = string.match(url_, "^(.-)/?$") # Breaks dl.
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and (allowed(url_, origurl) or force) then
      table.insert(urls, { url=url_ })
      --set_derived_url(url_)
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    -- Being caused to fail by a recursive call on "../"
    if not newurl then
      return
    end
    if string.match(newurl, "\\[uU]002[fF]") then
      return checknewurl(string.gsub(newurl, "\\[uU]002[fF]", "/"))
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check(absolute(url, "/" .. newurl))
    end
  end

  local function load_html()
    if html == nil then
      html = read_file(file)
    end
  end
  
  -- Originator b/c that's what the referer needs to be
  local function queue_afc(params, originator, originatingCBI)
    local data = ''
    for k, v in pairs(params) do
      if data ~= '' then
        data = data .. '&'
      end
      data = data .. urlparse.escape(k) .. "=" .. urlparse.escape(tostring(v))
    end
    print_debug("Data is " .. data)
    token7 = '6304e75ff709a523cb374c47258889e6'
    
    local cbi_component = "&callbackIndex=" .. tostring(callbackIndex)
    callbackOriginParmas[callbackIndex] = params
    
    if not originator then
      originator = callbackOriginatingPages[originatingCBI]
    end
    callbackOriginatingPages[callbackIndex] = originator
    
    callbackIndex = callbackIndex + 1
    table.insert(urls, {url="http://" .. current_item_value .. ".wikidot.com/ajax-module-connector.php", post_data=data .. cbi_component .. "&wikidot_token7=" .. token7, headers={Referer=originator}}) -- TODO suffix w/ the cookie (this is just what Firefox got, expires the 13th)
  end

  -- Start of wikis
  if string.match(url, "^https?://[^%./]+%.wikidot%.com/$") and current_item_type == "wiki" and status_code == 200 then
    --table.insert(urls, {url="http://" .. current_item_value .. ".wikidot.com/ajax-module-connector.php", data="moduleName=misc%2FCookiePolicyPlModule&callbackIndex=0&wikidot_token7=d176d812712a8a6d4d09af58033153b5"}) -- Old version
    queue_afc({moduleName="misc/CookiePolicyPlModule"}, url) -- Not sure what this is actually for, but if it is not present every page gets a permanent "loading" cursor
    check("http://" .. current_item_value .. ".wikidot.com/common--misc/blank.html") -- What it sounds like
    
    -- Some common pages that list other pages
    check("http://" .. current_item_value .. ".wikidot.com/system:list-all-pages")
    check("http://" .. current_item_value .. ".wikidot.com/forum")
    check("http://" .. current_item_value .. ".wikidot.com/forum:start")
    check("http://" .. current_item_value .. ".wikidot.com/nav:side") -- See http://community.wikidot.com/help:menu
    check("http://" .. current_item_value .. ".wikidot.com/nav:top") -- See http://community.wikidot.com/help:menu
    -- TODO check page tags
    -- TODO recent changes
    
  end
  
  -- Wiki pages
  if current_item_type == "wiki" and status_code == 200 then
    if string.match(url, "^http://[^/]+%.wikidot%.com/ajax%-module%-connector%.php$") then
      load_html()
      local json = JSON:decode(html)
      if json["status"] == "ok" then
        local orig_q = callbackOriginParmas[tonumber(json["callbackIndex"])]
        print("Orig module was " .. orig_q["moduleName"])
        
        -- History page
        if orig_q["moduleName"] == "history/PageRevisionListModule" then
          local versions = {}
          for vers in string.gmatch(json["body"], "showVersion%(([0-9]+)%)") do
            versions[vers] = true
          end
          for vers in string.gmatch(json["body"], "showSource%(([0-9]+)%)") do
            versions[vers] = true
          end
          
          for vers, _ in pairs(versions) do
            queue_afc({moduleName="history/PageVersionModule", revision_id=vers}, nil, tonumber(json["callbackIndex"])) -- View this version rendered
            queue_afc({moduleName="history/PageSourceModule", revision_id=vers}, nil, tonumber(json["callbackIndex"])) -- View this version's source
          end
          
          
        elseif orig_q["moduleName"] == "history/PageVersionModule" then
          -- Amazing ArchiveTeam technology to get links extracted
          assert(json["status"] == "ok")
          html = json["body"]
        end
      elseif json["status"] == "no_permission" then
        print("A-M-C status is no_permission, skipping")
      else
        -- The following is here for debugging purposes
        print("Bad A-M-C status, details follow")
        print(JSON:encode(json))
        print(JSON:encode(callbackOriginParmas[tonumber(json["callbackIndex"])])) -- If it fails to find, it will do the same thing as the next line anyhow
        error("Bad A-M-C status")
      end
    else
      load_html()
      local page_id = string.match(html, "WIKIREQUEST%.info%.pageId = ([0-9]+);")
      if page_id then
        queue_afc({moduleName="viewsource/ViewSourceModule", page_id=page_id}, url) -- View page source
        queue_afc({moduleName="history/PageHistoryModule", page_id=page_id}, url) -- Interface to view history
        -- CDN http://d3g0gp89917ko0.cloudfront.net/v--3e3a6f7dbcc9/common--modules/js/history/PageHistoryModule.js TODO
        queue_afc({moduleName="history/PageRevisionListModule", page_id=page_id, page=1, perpage=20, options='{"all":true}'}, url) -- First page of history
      end
    end
  end

  if status_code == 200 and not (string.match(url, "%.jpe?g$") or string.match(url, "%.png$")) then
    load_html()
    
    for user in string.gmatch(html, 'http://www%.wikidot%.com/user:info/([a-zA-Z0-9%-%_]+)') do
      discover_item("user", user)
    end
    
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
  end

  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()


  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if downloaded[newloc] == true or addedtolist[newloc] == true
            or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    --[[else
      set_derived_url(newloc)]]
    end
  end

  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end
  
  local do_retry = false
  local maxtries = 12
  local url_is_essential = true

  -- Whitelist instead of blacklist status codes
  local is_valid_403 = string.match(url["url"], "^https?://[^/%.]+%.wikidot%.com/common%-%-")
  if status_code ~= 200
    and is_on_targeted(url["url"])
    and not (status_code == 404) -- Because this site is editable, there are loads of weird 404s
    and not (status_code == 403 and is_valid_403)
    and not (status_code >= 300 and status_code <= 399) then
    print("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    do_retry = true
  end

  if not is_on_targeted(url["url"]) then
    maxtries = 2
  end


  if do_retry then
    if tries >= maxtries then
      print("I give up...\n")
      tries = 0
      if not url_is_essential then
        return wget.actions.EXIT
      else
        print("Failed on an essential URL, aborting...")
        return wget.actions.ABORT
      end
    else
      sleep_time = math.floor(math.pow(2, tries))
      tries = tries + 1
    end
  end


  if do_retry and sleep_time > 0.001 then
    print("Sleeping " .. sleep_time .. "s")
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0
  return wget.actions.NOTHING
end


wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  if do_debug then
    for item, _ in pairs(discovered_items) do
      print("Would have sent discovered item " .. item)
    end
  else
    local to_send = nil
    for item, _ in pairs(discovered_items) do
      assert(string.match(item, ":")) -- Message from EggplantN, #binnedtray (search "colon"?)
      if to_send == nil then
        to_send = item
      else
        to_send = to_send .. "\0" .. item
      end
      print("Queued " .. item)
    end

    if to_send ~= nil then
      local tries = 0
      while tries < 10 do
        local body, code, headers, status = http.request(
          --"http://blackbird.arpa.li:23038/tinkercad-n9szj9md96micct/",
          "http://example.com/",
          to_send
        )
        if code == 200 or code == 409 then
          break
        end
        os.execute("sleep " .. math.floor(math.pow(2, tries)))
        tries = tries + 1
      end
      if tries == 10 then
        abortgrab = true
      end
    end
  end
end

wget.callbacks.write_to_warc = function(url, http_stat)
  set_new_item(url["url"])
  return true
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

