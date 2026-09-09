///|
// js-only end-to-end for the host-side OAuth orchestration in mcp_login.mbt.
// Spawns the shared OAuth fixture from posoco-ext-mcp (one process playing
// resource server + authorization server; cwd is the cetas-js module root,
// so the fixture rides a relative path), then drives the same functions the
// host drives: discover/attach/activate captures the 401 challenge,
// mcp_login_flow lands a device-flow token with the refresh endpoints
// persisted, and an expired stored credential proves mcp_inject_stored_tokens
// refreshes and re-injects before the reconnecting call.

///|
#cfg(target="js")
extern "js" fn js_start_oauth_fixture(
  port_file : String,
) -> @js_async.Promise[Int] =
  #| async (port_file) => {
  #|   const { spawn } = await import('node:child_process')
  #|   return await new Promise((resolve, reject) => {
  #|     const child = spawn(process.execPath, ['../../extension/posoco-ext-mcp/test_fixtures/http_oauth_server.mjs', port_file], { stdio: 'ignore' })
  #|     child.once('spawn', () => resolve(child.pid))
  #|     child.once('error', (e) => reject(e))
  #|   })
  #| }

///|
#cfg(target="js")
extern "js" fn js_read_text_file(path : String) -> String =
  #| (p) => {
  #|   try { return require('node:fs').readFileSync(p, 'utf-8') } catch { return '' }
  #| }

///|
#cfg(target="js")
extern "js" fn js_write_text_file(path : String, content : String) -> Unit =
  #| (p, c) => {
  #|   const fs = require('node:fs')
  #|   fs.mkdirSync(p.substring(0, p.lastIndexOf('/')), { recursive: true })
  #|   fs.writeFileSync(p, c)
  #| }

///|
#cfg(target="js")
extern "js" fn js_kill_pid(pid : Int) -> Unit =
  #| (pid) => {
  #|   try { process.kill(pid) } catch {}
  #| }

///|
#cfg(target="js")
async test "js mcp login flow and startup token injection" {
  let port_file = "test_fixtures/.http_port_mcp_login"
  js_write_text_file(port_file, "")
  let pid = js_start_oauth_fixture(port_file).wait() catch { _ => -1 }
  if pid < 0 {
    fail("failed to spawn oauth fixture (relative fixture path unreachable?)")
  }
  let mut port = ""
  for _ in 0..<100 {
    port = js_read_text_file(port_file)
    if port != "" {
      break
    }
    @async.sleep(50)
  }
  if port == "" {
    js_kill_pid(pid)
    fail("oauth fixture did not report a port")
  }
  let dir = "test_fixtures/mcplogindir"
  js_write_text_file(
    dir + "/.mcp.json",
    "{\"mcpServers\":{\"oa\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:" +
    port +
    "/mcp\",\"auth\":\"oauth\"}}}",
  )
  let bridge = match
    @mcp.MCPToolBridge::discover(
      cwd=dir,
      user_mcp_json=dir + "/nohome/.cetas/mcp.json",
      mode=@mcp.LoadMode::Lazy,
    ) {
    Ok(bridge) => bridge
    Err(message) => {
      js_kill_pid(pid)
      fail("discover failed: " + message)
    }
  }
  // Activation eats the 401; the challenge is captured for the login flow.
  @async.with_task_group(group => {
    bridge.attach(group)
    inspect(bridge.activate().length(), content="1")
  })
  inspect(bridge.auth_challenge("oa") is Some(_), content="true")
  // The full login chain — the same function the intercepted /mcp login runs.
  let store = @oauth.InMemoryProviderCredentialStore::InMemoryProviderCredentialStore()
  let transport = @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
  let interaction = @oauth.NoopAuthInteraction::NoopAuthInteraction()
  let now = (@async.now() / 1000L).to_int()
  let login = mcp_login_flow(bridge, "oa", store, transport, interaction, now)
  match login {
    Ok(feedback) =>
      inspect(feedback, content="logged into 'oa'; 1 tool available")
    Err(reason) => {
      js_kill_pid(pid)
      fail("login flow failed: " + reason)
    }
  }
  // The stored record carries the two keys a later refresh needs.
  let stored = store.read("mcp.oa") catch { _ => None }
  let stored_cred = match stored {
    Some(@oauth.ProviderCredential::OAuth(credential)) => credential
    _ => {
      js_kill_pid(pid)
      fail("expected a stored OAuth credential for mcp.oa")
    }
  }
  inspect(
    stored_cred.metadata_value("token_endpoint") is Some(_),
    content="true",
  )
  inspect(stored_cred.metadata_value("client_id") is Some(_), content="true")
  // The reconnected server serves its tool through the fresh token.
  inspect(@posoco.ToolProvider::list_tools(bridge).length(), content="1")
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call_login"),
    name: @posoco.ToolName::unchecked("oa__oauth_tool"),
    arguments: Json::object(Map::from_array([])),
  }
  let outcome = @posoco.ToolProvider::execute(bridge, "oa__oauth_tool", call) catch {
    error => {
      js_kill_pid(pid)
      fail("execute after login failed: " + error.to_string())
    }
  }
  match outcome {
    Success(content~, ..) => inspect(content, content="oauth:ok")
    _ => {
      js_kill_pid(pid)
      fail("expected success outcome after login")
    }
  }
  // The startup pass's refresh branch: expire the stored record, re-inject.
  // The fixture's refresh grant revokes the access token issued with the
  // device flow, so the call below can only succeed with the refreshed token
  // on the wire.
  let expired = { ..stored_cred, expires_at: now - 10, }
  store.write("mcp.oa", @oauth.ProviderCredential::OAuth(expired)) catch {
    _ => {
      js_kill_pid(pid)
      fail("expiring the stored credential failed")
    }
  }
  mcp_inject_stored_tokens(bridge, store, transport, now)
  let reconnected : Result[Unit, String] = bridge.reconnect_server("oa") catch {
    _ => Err("reconnect aborted")
  }
  match reconnected {
    Ok(_) => ()
    Err(message) => {
      js_kill_pid(pid)
      fail("reconnect after injection failed: " + message)
    }
  }
  let call2 : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call_refresh_inject"),
    name: @posoco.ToolName::unchecked("oa__oauth_tool"),
    arguments: Json::object(Map::from_array([])),
  }
  let outcome2 = @posoco.ToolProvider::execute(bridge, "oa__oauth_tool", call2) catch {
    error => {
      js_kill_pid(pid)
      fail("execute after refresh injection failed: " + error.to_string())
    }
  }
  match outcome2 {
    Success(content~, ..) => inspect(content, content="oauth:ok")
    _ => {
      js_kill_pid(pid)
      fail("expected success outcome after refresh injection")
    }
  }
  // The rotated credential was persisted with the endpoints still on record.
  let rotated_record = store.read("mcp.oa") catch { _ => None }
  let rotated = match rotated_record {
    Some(@oauth.ProviderCredential::OAuth(credential)) => credential
    _ => {
      js_kill_pid(pid)
      fail("expected the rotated credential to be persisted")
    }
  }
  inspect(rotated.access_token != expired.access_token, content="true")
  inspect(rotated.expires_at > now, content="true")
  inspect(rotated.metadata_value("token_endpoint") is Some(_), content="true")
  inspect(rotated.metadata_value("client_id") is Some(_), content="true")
  bridge.close()
  js_kill_pid(pid)
}
