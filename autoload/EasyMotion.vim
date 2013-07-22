" EasyMotion - Vim motions on speed!
"
" Author: Kim Silkebækken <kim.silkebaekken+vim@gmail.com>
" Source repository: https://github.com/Lokaltog/vim-easymotion

" Default configuration functions {{{
	function! EasyMotion#InitOptions(options) " {{{
		for [key, value] in items(a:options)
			if ! exists('g:EasyMotion_' . key)
				exec 'let g:EasyMotion_' . key . ' = ' . string(value)
			endif
		endfor
	endfunction " }}}
	function! EasyMotion#InitHL(group, colors) " {{{
		let group_default = a:group . 'Default'

		" Prepare highlighting variables
		let guihl = printf('guibg=%s guifg=%s gui=%s', a:colors.gui[0], a:colors.gui[1], a:colors.gui[2])
		if !exists('g:CSApprox_loaded')
			let ctermhl = &t_Co == 256
				\ ? printf('ctermbg=%s ctermfg=%s cterm=%s', a:colors.cterm256[0], a:colors.cterm256[1], a:colors.cterm256[2])
				\ : printf('ctermbg=%s ctermfg=%s cterm=%s', a:colors.cterm[0], a:colors.cterm[1], a:colors.cterm[2])
		else
			let ctermhl = ''
		endif

		" Create default highlighting group
		execute printf('hi default %s %s %s', group_default, guihl, ctermhl)

		" Check if the hl group exists
		if hlexists(a:group)
			redir => hlstatus | exec 'silent hi ' . a:group | redir END

			" Return if the group isn't cleared
			if hlstatus !~ 'cleared'
				return
			endif
		endif

		" No colors are defined for this group, link to defaults
		execute printf('hi default link %s %s', a:group, group_default)
	endfunction " }}}
" }}}
" Helper functions {{{
	function! s:Message(message) " {{{
		echo 'EasyMotion: ' . a:message
	endfunction " }}}
	function! s:Prompt(message) " {{{
		echohl Question
		echo a:message . ': '
		echohl None
	endfunction " }}}
	function! s:VarReset(var, ...) " {{{
		if ! exists('s:var_reset')
			let s:var_reset = {}
		endif

		let buf = bufname("")

		if a:0 == 0 && has_key(s:var_reset, a:var)
			" Reset var to original value
			call setbufvar(buf, a:var, s:var_reset[a:var])
		elseif a:0 == 1
			let new_value = a:0 == 1 ? a:1 : ''

			" Store original value
			let s:var_reset[a:var] = getbufvar(buf, a:var)

			" Set new var value
			call setbufvar(buf, a:var, new_value)
		endif
	endfunction " }}}
	function! s:SetLines(lines, key) " {{{
		try
			" Try to join changes with previous undo block
			undojoin
		catch
		endtry

		for [line_num, line] in a:lines
			call setline(line_num, line[a:key])
		endfor
	endfunction " }}}
	function! s:GetChar() " {{{
		let char = getchar()

		if char == 27
			" Escape key pressed
			redraw

			call s:Message('Cancelled')

			return ''
		endif

		return nr2char(char)
	endfunction " }}}
" }}}
" Grouping algorithms {{{
	let s:grouping_algorithms = {
	\   1: 'SCTree'
	\ , 2: 'Original'
	\ }
	" Single-key/closest target priority tree {{{
		" This algorithm tries to assign one-key jumps to all the targets closest to the cursor.
		" It works recursively and will work correctly with as few keys as two.
		function! s:GroupingAlgorithmSCTree(targets, keys)
			" Prepare variables for working
			let targets_len = len(a:targets)
			let keys_len = len(a:keys)

			let groups = {}

			let keys = reverse(copy(a:keys))

			" Semi-recursively count targets {{{
				" We need to know exactly how many child nodes (targets) this branch will have
				" in order to pass the correct amount of targets to the recursive function.

				" Prepare sorted target count list {{{
					" This is horrible, I know. But dicts aren't sorted in vim, so we need to
					" work around that. That is done by having one sorted list with key counts,
					" and a dict which connects the key with the keys_count list.

					let keys_count = []
					let keys_count_keys = {}

					let i = 0
					for key in keys
						call add(keys_count, 0)

						let keys_count_keys[key] = i

						let i += 1
					endfor
				" }}}

				let targets_left = targets_len
				let level = 0
				let i = 0

				while targets_left > 0
					" Calculate the amount of child nodes based on the current level
					let childs_len = (level == 0 ? 1 : (keys_len - 1) )

					for key in keys
						" Add child node count to the keys_count array
						let keys_count[keys_count_keys[key]] += childs_len

						" Subtract the child node count
						let targets_left -= childs_len

						if targets_left <= 0
							" Subtract the targets left if we added too many too
							" many child nodes to the key count
							let keys_count[keys_count_keys[key]] += targets_left

							break
						endif

						let i += 1
					endfor

					let level += 1
				endwhile
			" }}}
			" Create group tree {{{
				let i = 0
				let key = 0

				call reverse(keys_count)

				for key_count in keys_count
					if key_count > 1
						" We need to create a subgroup
						" Recurse one level deeper
						let groups[a:keys[key]] = s:GroupingAlgorithmSCTree(a:targets[i : i + key_count - 1], a:keys)
					elseif key_count == 1
						" Assign single target key
						let groups[a:keys[key]] = a:targets[i]
					else
						" No target
						continue
					endif

					let key += 1
					let i += key_count
				endfor
			" }}}

			" Finally!
			return groups
		endfunction
	" }}}
	" Original {{{
		function! s:GroupingAlgorithmOriginal(targets, keys)
			" Split targets into groups (1 level)
			let targets_len = len(a:targets)
			let keys_len = len(a:keys)

			let groups = {}

			let i = 0
			let root_group = 0
			try
				while root_group < targets_len
					let groups[a:keys[root_group]] = {}

					for key in a:keys
						let groups[a:keys[root_group]][key] = a:targets[i]

						let i += 1
					endfor

					let root_group += 1
				endwhile
			catch | endtry

			" Flatten the group array
			if len(groups) == 1
				let groups = groups[a:keys[0]]
			endif

			return groups
		endfunction
	" }}}
	" Coord/key dictionary creation {{{
		function! s:CreateCoordKeyDict(groups, ...)
			" Dict structure:
			" 1,2 : a
			" 2,3 : b
			let sort_list = []
			let coord_keys = {}
			let group_key = a:0 == 1 ? a:1 : ''

			for [key, item] in items(a:groups)
				let key = ( ! empty(group_key) ? group_key : key)

				if type(get(item, 'target')) == 3
					" Destination coords

					" The key needs to be zero-padded in order to
					" sort correctly
					let dict_key = printf('%s,%s,%05d,%05d', substitute(item.buffer,',','_','g'), item.window, item.target[0], item.target[1])
					let coord_keys[dict_key] = key

					" We need a sorting list to loop correctly in
					" PromptUser, dicts are unsorted
					call add(sort_list, dict_key)
				else
					" Item is a dict (has children)
					let coord_key_dict = s:CreateCoordKeyDict(item, key)

					" Make sure to extend both the sort list and the
					" coord key dict
					call extend(sort_list, coord_key_dict[0])
					call extend(coord_keys, coord_key_dict[1])
				endif

				unlet item
			endfor

			return [sort_list, coord_keys]
		endfunction
	" }}}
" }}}
	function! s:SwitchWindow(window)
		exe a:window.'wincmd w'
	endfunction
" Core functions {{{
	function! s:PromptUser(groups) "{{{
		" If only one possible match, jump directly to it {{{
			let group_values = values(a:groups)

			if len(group_values) == 1
				redraw

				return group_values[0]
			endif
		" }}}
		" Prepare marker lines {{{
			let windowLines = {}
			let windowHLCoords = {}
			let coord_key_dict = s:CreateCoordKeyDict(a:groups)
			for dict_key in sort(coord_key_dict[0])
				let target_key = coord_key_dict[1][dict_key]
				let [bufferName, window, line_num, col_num] = split(dict_key, ',')

				let line_num = str2nr(line_num)
				let col_num = str2nr(col_num)

				" Setup line dictionary
				if ! has_key(windowLines, window)
					let windowLines[window] = {}
					let windowHLCoords[window] = []
				endif

				let hl_coords = windowHLCoords[window]
				let lines = windowLines[window]
				call s:SwitchWindow(window)

				" Add original line and marker line
				if ! has_key(lines, line_num)
					let current_line = getline(line_num)

					let lines[line_num] = { 'orig': current_line, 'marker': current_line, 'mb_compensation': 0 }
				endif

				" Compensate for byte difference between marker
				" character and target character
				"
				" This has to be done in order to match the correct
				" column; \%c matches the byte column and not display
				" column.
				let target_char_len = strlen(matchstr(lines[line_num]['marker'], '\%' . col_num . 'c.'))
				let target_key_len = strlen(target_key)

				" Solve multibyte issues by matching the byte column
				" number instead of the visual column
				let col_num -= lines[line_num]['mb_compensation']

				if strlen(lines[line_num]['marker']) > 0
					" Substitute marker character if line length > 0
					let lines[line_num]['marker'] = substitute(lines[line_num]['marker'], '\%' . col_num . 'c.', target_key, '')
				else
					" Set the line to the marker character if the line is empty
					let lines[line_num]['marker'] = target_key
				endif

				" Add marker/target lenght difference for multibyte
				" compensation
				let lines[line_num]['mb_compensation'] += (target_char_len - target_key_len)


				" Add highlighting coordinates
				call add(hl_coords, '\%' . line_num . 'l\%' . col_num . 'c')
			endfor

		" }}}
		" Highlight targets {{{
			for [window, hl_coords] in items(windowHLCoords)	
				call s:SwitchWindow(window)
				let windowHLCoords[window] = matchadd(g:EasyMotion_hl_group_target, join(hl_coords, '\|'), 1)
			endfor
		" }}}

		try
			" Set lines with markers
			for [window, lines] in items(windowLines)
				call s:SwitchWindow(window)
				call s:SetLines(items(lines), 'marker')
			endfor

			redraw

			" Get target character {{{
				call s:Prompt('Target key')

				let char = s:GetChar()
			" }}}
		finally
			" Restore original lines
			for [window, lines] in items(windowLines)
				call s:SwitchWindow(window)
				call s:SetLines(items(lines), 'orig')
			endfor

			" Un-highlight targets {{{
				for [window, target_hl_id] in items(windowHLCoords)
					call s:SwitchWindow(window)
					call matchdelete(target_hl_id)
				endfor
			" }}}

			redraw
		endtry

		" Check if we have an input char {{{
			if empty(char)
				throw 'Cancelled'
			endif
		" }}}
		" Check if the input char is valid {{{
			if ! has_key(a:groups, char)
				throw 'Invalid target'
			endif
		" }}}

		let target = a:groups[char]

		let testTarget = get(target, 'target')
		if type(testTarget) == 3
			" Return target coordinates
			return target
		else
			" Prompt for new target character
			return s:PromptUser(target)
		endif
	endfunction "}}}
	function! s:MatchWindow(regex, match_mod)
		let targets = []
		" loop over every line on the screen (just the visible lines)
		for row in range(line('w0'), line('w$'))
			" find all columns on this line where a word begins with our letter
			let col = 0
			let src = ' '.getline(row)
			let matchCol = match(src, a:regex, col)
			while matchCol != -1
				" store any matching row/col positions
				call add(targets, [row, matchCol + a:match_mod])
				let col = matchCol + 1
				let matchCol = match(src, a:regex, col)
			endwhile
		endfor
		return targets
	endfunction
	function! s:MatchChar(char, container)
                let bufName = expand("%")
                " Don't match in non-file windows
                if len(bufName) == 0
                  return
                endif

		let current = winnr()
		let targets = s:MatchWindow('\c.\<'.a:char, 1)
		if len(targets) == 0
			let targets = s:MatchWindow('\' . a:char . '\@<!\' . a:char, 0)
		endif
		if len(targets) > 0
			let a:container[current] = {'buffer': expand("%:p"),'targets':targets}
		endif
	endfunction

	function! EasyMotion(visualmode) " {{{
		" prompt for and capture user's search character
		echo "AceJump to words starting with letter: "
		let char = s:GetChar()
		if empty(char)
			return
		endif

		let orig_pos = [line('.'), col('.')]
		let originalWindow = winnr()
		try
			" Reset properties {{{
				call s:VarReset('&scrolloff', 0)
				call s:VarReset('&modified', 0)
				call s:VarReset('&modifiable', 1)
				call s:VarReset('&readonly', 0)
				call s:VarReset('&spell', 0)
				call s:VarReset('&virtualedit', '')
			" }}}

			" Shade inactive source {{{
				if g:EasyMotion_do_shade
					 let shade_hl_ids = {}
					 windo let shade_hl_ids[winnr()] = matchadd(g:EasyMotion_hl_group_shade, '\%'.line('w0').'l\_.*\%'.line('w$').'l', 0)
				endif
			" }}}
			let container = {}
			windo call s:MatchChar(char, container)
			if empty(container)
				throw 'No matches'
			endif

			let targets = []
			let hashes = {}
			for [windowNumber, windowTargets] in items(container)
				for target in windowTargets.targets
					let hashKey = windowTargets.buffer . string(target)
					if type(get(hashes,hashKey)) == 0
						call add(targets, {'target':target,'window': windowNumber, 'buffer' : windowTargets.buffer})
					endif
					let hashes[hashKey] = ''
					
				endfor
			endfor
			if len(targets) > (len(g:EasyMotion_keys)*3)
				throw "Too many matches."
			endif

			let GroupingFn = function('s:GroupingAlgorithm' . s:grouping_algorithms[g:EasyMotion_grouping])
			let groups = GroupingFn(targets, split(g:EasyMotion_keys, '\zs'))

			" Prompt user for target group/character
			let coords = s:PromptUser(groups)

			" Update selection {{{
		"		if ! empty(a:visualmode)
		"			keepjumps call cursor(orig_pos[0], orig_pos[1])

			"		exec 'normal! ' . a:visualmode
			"	endif
			" }}}

			" Update cursor position
			"call cursor(orig_pos[0], orig_pos[1])
			"mark '
			call s:SwitchWindow(coords.window)
			let originalWindow = coords.window

			call cursor(coords.target[0], coords.target[1])
			call s:Message('Jumping to [' . coords.target[0] . ', ' . coords.target[1] . '] in window ' . coords.window)
		catch
			redraw

			" Show exception message
			call s:Message(v:exception)

			" Restore original cursor position/selection {{{
				if ! empty(a:visualmode)
					silent exec 'normal! gv'
				else
					keepjumps call cursor(orig_pos[0], orig_pos[1])
				endif
			" }}}
			call s:SwitchWindow(originalWindow)
		finally
			" Restore properties {{{
				call s:VarReset('&scrolloff')
				call s:VarReset('&modified')
				call s:VarReset('&modifiable')
				call s:VarReset('&readonly')
				call s:VarReset('&spell')
				call s:VarReset('&virtualedit')
			" }}}
			" Remove shading {{{
				if g:EasyMotion_do_shade && exists('shade_hl_ids')
					windo call matchdelete(shade_hl_ids[winnr()])
					call s:SwitchWindow(originalWindow)
				endif
			" }}}
		endtry
	endfunction " }}}
" }}}

" vim: fdm=marker:noet:ts=4:sw=4:sts=4
