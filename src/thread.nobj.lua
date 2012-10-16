-- Copyright (c) 2011 by Robert G. Jakabosky <bobby@sharedrealm.com>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

object "Lua_LLThread" {
	c_source[[

/* maximum recursive depth of table copies. */
#define MAX_COPY_DEPTH 30

#ifdef __WINDOWS__
#include <windows.h>
#include <stdio.h>
#include <process.h>
#else
#include <pthread.h>
#include <stdio.h>
#endif

typedef enum {
	TSTATE_NONE     = 0,
	TSTATE_STARTED  = 1<<0,
	TSTATE_DETACHED = 1<<1,
	TSTATE_JOINED   = 1<<2,
} Lua_TState;

typedef struct Lua_LLThread_child {
	lua_State  *L;
	int        status;
	int        is_detached;
} Lua_LLThread_child;

typedef struct Lua_LLThread {
	Lua_LLThread_child *child;
#ifdef __WINDOWS__
	HANDLE     thread;
#else
	pthread_t  thread;
#endif
	Lua_TState state;
} Lua_LLThread;

#define ERROR_LEN 1024

/******************************************************************************
* traceback() function from Lua 5.1/5.2 source.
* Copyright (C) 1994-2008 Lua.org, PUC-Rio.  All rights reserved.
*
* Permission is hereby granted, free of charge, to any person obtaining
* a copy of this software and associated documentation files (the
* "Software"), to deal in the Software without restriction, including
* without limitation the rights to use, copy, modify, merge, publish,
* distribute, sublicense, and/or sell copies of the Software, and to
* permit persons to whom the Software is furnished to do so, subject to
* the following conditions:
*
* The above copyright notice and this permission notice shall be
* included in all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
******************************************************************************/
#if !defined(LUA_VERSION_NUM) || (LUA_VERSION_NUM == 501)
/* from Lua 5.1 */
static int traceback (lua_State *L) {
  if (!lua_isstring(L, 1))  /* 'message' not a string? */
    return 1;  /* keep it intact */
  lua_getglobal(L, "debug");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    return 1;
  }
  lua_getfield(L, -1, "traceback");
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 2);
    return 1;
  }
  lua_pushvalue(L, 1);  /* pass error message */
  lua_pushinteger(L, 2);  /* skip this function and traceback */
  lua_call(L, 2, 1);  /* call debug.traceback */
  return 1;
}
#else
/* from Lua 5.2 */
static int traceback (lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  if (msg)
    luaL_traceback(L, L, msg, 1);
  else if (!lua_isnoneornil(L, 1)) {  /* is there an error object? */
    if (!luaL_callmeta(L, 1, "__tostring"))  /* try its 'tostring' metamethod */
      lua_pushliteral(L, "(no error message)");
  }
  return 1;
}
#endif

static Lua_LLThread_child *llthread_child_new() {
	Lua_LLThread_child *this;

	this = (Lua_LLThread_child *)calloc(1, sizeof(Lua_LLThread_child));
	/* create new lua_State for the thread. */
	this->L = luaL_newstate();
	/* open standard libraries. */
	luaL_openlibs(this->L);
	/* push traceback function as first value on stack. */
	lua_pushcfunction(this->L, traceback);

	return this;
}

static void llthread_child_destroy(Lua_LLThread_child *this) {
	lua_close(this->L);
	free(this);
}

static Lua_LLThread *llthread_new() {
	Lua_LLThread *this;

	this = (Lua_LLThread *)calloc(1, sizeof(Lua_LLThread));
	this->state = TSTATE_NONE;
	this->child = llthread_child_new();

	return this;
}

static void llthread_cleanup_child(Lua_LLThread *this) {
	if(this->child) {
		llthread_child_destroy(this->child);
		this->child = NULL;
	}
}

static void llthread_destroy(Lua_LLThread *this) {
	/* We still own the child thread object iff the thread was not started or
	 * we have joined the thread.
	 */
	if((this->state & TSTATE_JOINED) == TSTATE_JOINED || this->state == TSTATE_NONE) {
		llthread_cleanup_child(this);
	}
	free(this);
}

#ifdef __WINDOWS__
static void run_child_thread(void *arg) {
#else
static void *run_child_thread(void *arg) {
#endif
	Lua_LLThread_child *this = (Lua_LLThread_child *)arg;
	lua_State *L = this->L;
	int nargs = lua_gettop(L) - 2;

	this->status = lua_pcall(L, nargs, LUA_MULTRET, 1);

	/* alwasy print errors here, helps with debugging bad code. */
	if(this->status != 0) {
		const char *err_msg = lua_tostring(L, -1);
		fprintf(stderr, "Error from thread: %s\n", err_msg);
		fflush(stderr);
	}

	/* if thread is detached, then destroy the child state. */
	if(this->is_detached != 0) {
		/* thread is detached, so it must clean-up the child state. */
		llthread_child_destroy(this);
		this = NULL;
	}
#ifdef __WINDOWS__
	if(this) {
		/* attached thread, don't close thread handle. */
		_endthreadex(0);
	} else {
		/* detached thread, close thread handle. */
		_endthread();
	}
#else
	return this;
#endif
}

static int llthread_start(Lua_LLThread *this, int start_detached) {
	Lua_LLThread_child *child;
	int rc = 0;

	child = this->child;
	child->is_detached = start_detached;
#ifdef __WINDOWS__
	this->thread = (HANDLE)_beginthread(run_child_thread, 0, child);
	if(this->thread != (HANDLE)-1L) {
		this->state = TSTATE_STARTED;
		if(start_detached) {
			this->state |= TSTATE_DETACHED;
			this->child = NULL;
		}
	}
#else
	rc = pthread_create(&(this->thread), NULL, run_child_thread, child);
	if(rc == 0) {
		this->state = TSTATE_STARTED;
		if(start_detached) {
			this->state |= TSTATE_DETACHED;
			this->child = NULL;
			rc = pthread_detach(this->thread);
		}
	}
#endif
	return rc;
}

static int llthread_join(Lua_LLThread *this) {
#ifdef __WINDOWS__
	WaitForSingleObject( this->thread, INFINITE );
	/* Destroy the thread object. */
	CloseHandle( this->thread );

	this->state |= TSTATE_JOINED;

	return 0;
#else
	int rc;

	/* then join the thread. */
	rc = pthread_join(this->thread, NULL);
	if(rc == 0) {
		this->state |= TSTATE_JOINED;
	}
	return rc;
#endif
}

typedef struct {
	lua_State *from_L;
	lua_State *to_L;
	int has_cache;
	int cache_idx;
	int is_arg;
} llthread_copy_state;

static int llthread_copy_table_from_cache(llthread_copy_state *state, int idx) {
	void *ptr;

	/* convert table to pointer for lookup in cache. */
	ptr = (void *)lua_topointer(state->from_L, idx);
	if(ptr == NULL) return 0; /* can't convert to pointer. */

	/* check if we need to create the cache. */
	if(!state->has_cache) {
		lua_newtable(state->to_L);
		lua_replace(state->to_L, state->cache_idx);
		state->has_cache = 1;
	}

	lua_pushlightuserdata(state->to_L, ptr);
	lua_rawget(state->to_L, state->cache_idx);
	if(lua_isnil(state->to_L, -1)) {
		/* not in cache. */
		lua_pop(state->to_L, 1);
		/* create new table and add to cache. */
		lua_newtable(state->to_L);
		lua_pushlightuserdata(state->to_L, ptr);
		lua_pushvalue(state->to_L, -2);
		lua_rawset(state->to_L, state->cache_idx);
		return 0;
	}
	/* found table in cache. */
	return 1;
}

static int llthread_copy_value(llthread_copy_state *state, int depth, int idx) {
	const char *str;
	size_t str_len;
	int kv_pos;

	/* Maximum recursive depth */
	if(++depth > MAX_COPY_DEPTH) {
		return luaL_error(state->from_L, "Hit maximum copy depth (%d > %d).", depth, MAX_COPY_DEPTH);
	}

	/* only support string/number/boolean/nil/table/lightuserdata. */
	switch(lua_type(state->from_L, idx)) {
	case LUA_TNIL:
		lua_pushnil(state->to_L);
		break;
	case LUA_TNUMBER:
		lua_pushnumber(state->to_L, lua_tonumber(state->from_L, idx));
		break;
	case LUA_TBOOLEAN:
		lua_pushboolean(state->to_L, lua_toboolean(state->from_L, idx));
		break;
	case LUA_TSTRING:
		str = lua_tolstring(state->from_L, idx, &(str_len));
		lua_pushlstring(state->to_L, str, str_len);
		break;
	case LUA_TLIGHTUSERDATA:
		lua_pushlightuserdata(state->to_L, lua_touserdata(state->from_L, idx));
		break;
	case LUA_TTABLE:
		/* make sure there is room on the new state for 3 values (table,key,value) */
		if(!lua_checkstack(state->to_L, 3)) {
			return luaL_error(state->from_L, "To stack overflow!");
		}
		/* make room on from stack for key/value pairs. */
		luaL_checkstack(state->from_L, 2, "From stack overflow!");

		/* check cache for table. */
		if(llthread_copy_table_from_cache(state, idx)) {
			/* found in cache don't need to copy table. */
			break;
		}
		lua_pushnil(state->from_L);
		while (lua_next(state->from_L, idx) != 0) {
			/* key is at (top - 1), value at (top), but we need to normalize these
			 * to positive indices */
			kv_pos = lua_gettop(state->from_L);
			/* copy key */
			llthread_copy_value(state, depth, kv_pos - 1);
			/* copy value */
			llthread_copy_value(state, depth, kv_pos);
			/* Copied key and value are now at -2 and -1 in state->to_L. */
			lua_settable(state->to_L, -3);
			/* Pop value for next iteration */
			lua_pop(state->from_L, 1);
		}
		break;
	case LUA_TFUNCTION:
	case LUA_TUSERDATA:
	case LUA_TTHREAD:
	default:
		if (state->is_arg) {
			return luaL_argerror(state->from_L, idx, "function/userdata/thread types un-supported.");
		} else {
			/* convert un-supported types to an error string. */
			lua_pushfstring(state->to_L, "Un-supported value: %s: %p",
				lua_typename(state->from_L, lua_type(state->from_L, idx)), lua_topointer(state->from_L, idx));
		}
	}

	return 1;
}

static int llthread_copy_values(lua_State *from_L, lua_State *to_L, int idx, int top, int is_arg) {
	llthread_copy_state state;
	int nvalues = 0;
	int n;

	nvalues = (top - idx) + 1;
	/* make sure there is room on the new state for the values. */
	if(!lua_checkstack(to_L, nvalues + 1)) {
		return luaL_error(from_L, "To stack overflow!");
	}

	/* setup copy state. */
	state.from_L = from_L;
	state.to_L = to_L;
	state.is_arg = is_arg;
	state.has_cache = 0; /* don't create cache table unless it is needed. */
	lua_pushnil(to_L);
	state.cache_idx = lua_gettop(to_L);

	nvalues = 0;
	for(n = idx; n <= top; n++) {
		llthread_copy_value(&state, 0, n);
		++nvalues;
	}

	/* remove cache table. */
	lua_remove(to_L, state.cache_idx);

	return nvalues;
}

static int llthread_push_args(lua_State *L, Lua_LLThread_child *child, int idx, int top) {
	return llthread_copy_values(L, child->L, idx, top, 1 /* is_arg */);
}

static int llthread_push_results(lua_State *L, Lua_LLThread_child *child, int idx, int top) {
	return llthread_copy_values(child->L, L, idx, top, 0 /* is_arg */);
}

static Lua_LLThread *llthread_create(lua_State *L, const char *code, size_t code_len) {
	Lua_LLThread *this;
	Lua_LLThread_child *child;
	const char *str;
	size_t str_len;
	int rc;
	int top;

	this = llthread_new();
	child = this->child;
	/* load Lua code into child state. */
	rc = luaL_loadbuffer(child->L, code, code_len, code);
	if(rc != 0) {
		/* copy error message to parent state. */
		str = lua_tolstring(child->L, -1, &(str_len));
		if(str != NULL) {
			lua_pushlstring(L, str, str_len);
		} else {
			/* non-string error message. */
			lua_pushfstring(L, "luaL_loadbuffer() failed to load Lua code: rc=%d", rc);
		}
		llthread_destroy(this);
		lua_error(L);
		return NULL;
	}
	/* copy extra args from main state to child state. */
	top = lua_gettop(L);
	/* Push all args after the Lua code. */
	llthread_push_args(L, child, 2, top);

	return this;
}

]],
	destructor {
		c_source "pre" [[
	Lua_LLThread_child *child;
]],
		c_source[[
	/* if the thread has been started and has not been detached/joined. */
	if((${this}->state & TSTATE_STARTED) == TSTATE_STARTED &&
			(${this}->state & (TSTATE_DETACHED|TSTATE_JOINED)) == 0) {
		/* then join the thread. */
		llthread_join(${this});
		child = ${this}->child;
		if(child && child->status != 0) {
			const char *err_msg = lua_tostring(child->L, -1);
			fprintf(stderr, "Error from non-joined thread: %s\n", err_msg);
			fflush(stderr);
		}
	}
	llthread_destroy(${this});
]]
	},
	method "start" {
		var_in{ "bool", "start_detached", is_optional = true },
		var_out{ "bool", "res" },
		c_source "pre" [[
	char buf[ERROR_LEN];
	int rc;
]],
		c_source[[
	if(${this}->state != TSTATE_NONE) {
		lua_pushboolean(L, 0); /* false */
		lua_pushliteral(L, "Thread already started.");
		return 2;
	}
	if((rc = llthread_start(${this}, ${start_detached})) != 0) {
		lua_pushboolean(L, 0); /* false */
		strerror_r(errno, buf, ERROR_LEN);
		lua_pushstring(L, buf);
		return 2;
	}
	${res} = true;
]]
	},
	method "join" {
		var_out{ "bool", "res" },
		var_out{ "const char *", "err_msg" },
		c_source "pre" [[
	Lua_LLThread_child *child;
	char buf[ERROR_LEN];
	int top;
	int rc;
]],
		c_source[[
	if((${this}->state & TSTATE_STARTED) == 0) {
		lua_pushboolean(L, 0); /* false */
		lua_pushliteral(L, "Can't join a thread that hasn't be started.");
		return 2;
	}
	if((${this}->state & TSTATE_DETACHED) == TSTATE_DETACHED) {
		lua_pushboolean(L, 0); /* false */
		lua_pushliteral(L, "Can't join a thread that has been detached.");
		return 2;
	}
	if((${this}->state & TSTATE_JOINED) == TSTATE_JOINED) {
		lua_pushboolean(L, 0); /* false */
		lua_pushliteral(L, "Can't join a thread that has already been joined.");
		return 2;
	}
	/* join the thread. */
	rc = llthread_join(${this});
	child = ${this}->child;

	/* Push all results after the Lua code. */
	if(rc == 0 && child) {
		if(child->status != 0) {
			const char *err_msg = lua_tostring(child->L, -1);
			lua_pushboolean(L, 0);
			lua_pushfstring(L, "Error from child thread: %s", err_msg);
			top = 2;
		} else {
			lua_pushboolean(L, 1);
			top = lua_gettop(child->L);
			/* return results to parent thread. */
			llthread_push_results(L, child, 2, top);
		}
		llthread_cleanup_child(${this});
		return top;
	} else {
		${res} = false;
		${err_msg} = buf;
		strerror_r(errno, buf, ERROR_LEN);
	}
	llthread_cleanup_child(${this});
]]
	},
}

