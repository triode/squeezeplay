/*
** Copyright 2007 Logitech. All Rights Reserved.
**
** This file is subject to the Logitech Public Source License Version 1.0. Please see the LICENCE file for details.
*/


#include "common.h"
#include "ui/jive.h"
#include "audio/fixed_math.h"


struct jive_sample {
	unsigned int refcount;
	Uint8 *data;
	size_t len;
	size_t pos;
	int mixer;
	bool enabled;
};


/* mixer channels */
#define MAX_SAMPLES 2
static struct jive_sample *sample[MAX_SAMPLES];

#define MAXVOLUME 100
static fft_fixed effect_gain = FIXED_ONE;
static int effect_volume;


static void sample_free(struct jive_sample *sample) {
	if (--sample->refcount > 0) {
		return;
	}

	if (sample->data) {
		free(sample->data);
	}
	free(sample);
}


void decode_sample_mix(Uint8 *buffer, size_t buflen) {
	const Sint64 max_sample = 0x7fffffffLL;
	const Sint64 min_sample = -0x80000000LL;
	int i;

	/* fixme: this crudely mixes the samples onto the buffer */
	for (i=0; i<MAX_SAMPLES; i++) {
		Sint32 *s, *d;
		size_t j, len;

		if (!sample[i]) {
			continue;
		}

		len = sample[i]->len - sample[i]->pos;
		if (len > buflen) {
			len = buflen;
		}

		s = (Sint32 *)(void *)(sample[i]->data + sample[i]->pos);
		d = (Sint32 *)(void *)buffer;
		for (j=0; j<len>>2; j++) {
			Sint64 tmp = *(s++);
			tmp = fixed_mul(effect_gain, tmp);
			tmp += *d;

			if (tmp >= max_sample) {
				tmp = max_sample;
			}
			else if (tmp <= min_sample) {
				tmp = min_sample;
			}
			*(d++) = tmp;
		}

		sample[i]->pos += len;

		if (sample[i]->pos == sample[i]->len) {
			sample[i]->pos = 0;

			sample_free(sample[i]);
			sample[i] = NULL;
		}
	}
}


static int decode_sample_obj_gc(lua_State *L) {
	struct jive_sample *sample = *(struct jive_sample **)lua_touserdata(L, 1);
	if (sample) {
		sample_free(sample);
	}

	return 0;
}


static int decode_sample_obj_play(lua_State *L) {
	struct jive_sample *snd;

	/* stack is:
	 * 1: sound
	 */

	snd = *(struct jive_sample **)lua_touserdata(L, -1);
	if (!snd->enabled) {
		return 0;
	}

	// lock

	if (sample[snd->mixer] != NULL) {
		/* slot if not free */
		// unlock
		return 0;
	}

	sample[snd->mixer] = snd;
	sample[snd->mixer]->refcount++;
	// unlock

	return 0;
}


static int decode_sample_obj_enable(lua_State *L) {
	struct jive_sample *snd;

	/* stack is:
	 * 1: sound
	 * 2: enabled
	 */

	snd = *(struct jive_sample **)lua_touserdata(L, 1);
	snd->enabled = lua_toboolean(L, 2);

	return 0;
}


static int decode_sample_obj_is_enabled(lua_State *L) {
	struct jive_sample *snd;

	/* stack is:
	 * 1: sound
	 */

	snd = *(struct jive_sample **)lua_touserdata(L, 1);
	lua_pushboolean(L, snd->enabled);

	return 1;
}


static struct jive_sample *load_sound(char *filename, int mixer) {
	struct jive_sample *snd;
	SDL_AudioSpec wave;
	SDL_AudioCVT cvt;
	Uint8 *data;
	Uint32 len;
	int i;

	// FIXME rewrite to not use SDL
	if (SDL_LoadWAV(filename, &wave, &data, &len) == NULL) {
		fprintf(stderr, "Couldn't load sound %s: %s\n", filename, SDL_GetError());
		return NULL;
	}

	/* Convert to signed 16 bit stereo */
	if (SDL_BuildAudioCVT(&cvt, wave.format, wave.channels, wave.freq,
			      AUDIO_S16, 2, 44100) < 0) {
		fprintf(stderr, "Couldn't build audio converter: %s\n", SDL_GetError());
		SDL_FreeWAV(data);
		return NULL;
	}
	cvt.buf = malloc(len * cvt.len_mult * 2);
	memcpy(cvt.buf, data, len);
	cvt.len = len;
	
	if (SDL_ConvertAudio(&cvt) < 0) {
		fprintf(stderr, "Couldn't convert audio: %s\n", SDL_GetError());
		SDL_FreeWAV(data);
		free(cvt.buf);
		return NULL;
	}
	SDL_FreeWAV(data);

	/* Convert to signed 32 bit stereo, SDL does not support this format */
	cvt.len_cvt *= 2;
	for (i=(cvt.len_cvt/4)-1; i>=0; i--) {
		((Uint32 *)(void *)cvt.buf)[i] = ((Uint16 *)(void *)cvt.buf)[i] << 16;
	}

	snd = malloc(sizeof(struct jive_sample));
	snd->refcount = 1;
	snd->data = cvt.buf;
	snd->len = cvt.len_cvt;
	snd->pos = 0;
	snd->mixer = mixer;
	snd->enabled = true;

	return snd;
}


static int decode_sample_load(lua_State *L) {
	struct jive_sample **snd;
	char fullpath[PATH_MAX];
	
	/* stack is:
	 * 1: audio
	 * 2: filename
	 * 3: mixer
	 */

	/* load sample */
	lua_getfield(L, LUA_REGISTRYINDEX, "jive.samples");
	lua_pushvalue(L, 2); // filename
	lua_gettable(L, -2);

	if (lua_isnil(L, -1)) {
		lua_pop(L, 1);

		if (!jive_find_file(lua_tostring(L, 2), fullpath)) {
			printf("Cannot find sound %s\n", lua_tostring(L, 2));
			return 0;
		}

		snd = (struct jive_sample **)lua_newuserdata(L, sizeof(struct jive_sample *));
		*snd = load_sound(fullpath, luaL_optinteger(L, 3, 0));

		if (*snd == NULL) {
			return 0;
		}

		luaL_getmetatable(L, "squeezeplay.sample.obj");
		lua_setmetatable(L, -2);

		lua_pushvalue(L, 2);
		lua_pushvalue(L, -2);
		lua_settable(L, -4);
	}

	return 1;
}


static int decode_sample_set_effect_volume(lua_State *L) {
	/* stack is:
	 * 1: sound
	 * 2: enabled
	 */

	effect_volume = lua_tointeger(L, 2);

	if (effect_volume < 0) {
		effect_volume = 0;
	}
	if (effect_volume > MAXVOLUME) {
		effect_volume = MAXVOLUME;
	}

	effect_gain = fixed_div(s32_to_fixed(effect_volume),
				s32_to_fixed(MAXVOLUME));

	return 0;
}


static int decode_sample_get_effect_volume(lua_State *L) {
	lua_pushinteger(L, effect_volume);
	return 1;
}


static const struct luaL_Reg sample_m[] = {
	{ "__gc", decode_sample_obj_gc },
	{ "play", decode_sample_obj_play },
	{ "enable", decode_sample_obj_enable },
	{ "isEnabled", decode_sample_obj_is_enabled },
	{ NULL, NULL }
};

static const struct luaL_Reg sample_f[] = {
	{ "loadSample", decode_sample_load },
	{ "setEffectVolume", decode_sample_set_effect_volume },
	{ "getEffectVolume", decode_sample_get_effect_volume },
	{ NULL, NULL }
};


int decode_sample_init(lua_State *L) {
	JIVEL_STACK_CHECK_BEGIN(L);

	/* sample cache */
	lua_newtable(L);
	lua_setfield(L, LUA_REGISTRYINDEX, "jive.samples");

	/* sound methods */
	luaL_newmetatable(L, "squeezeplay.sample.obj");

	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__index");

	luaL_register(L, NULL, sample_m);

	/* sound class */
	luaL_register(L, "squeezeplay.sample", sample_f);

	lua_pushinteger(L, MAXVOLUME);
	lua_setfield(L, -2, "MAXVOLUME");

	lua_pop(L, 2);

	JIVEL_STACK_CHECK_END(L);

	return 0;
}
