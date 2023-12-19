local lpeg = require "lpeg"
local P, C, Cg, Cc, Cmt, Ct, Cb, Cp, Cf, Cs, S, V, R =
	lpeg.P, lpeg.C, lpeg.Cg, lpeg.Cc, lpeg.Cmt, lpeg.Ct, lpeg.Cb, lpeg.Cp, lpeg.Cf, lpeg.Cs, lpeg.S, lpeg.V, lpeg.R

-- SLN
-- expressions, atoms, lists
-- documentation for the SLN: https://scopes.readthedocs.io/en/latest/dataformat/
-- a python SLN parser: https://github.com/salotz/python-sln/blob/master/src/sln/parser.py

local anchor_mt = {

	__lt = function(fst, snd)
		return snd.line > fst.line or (snd.line == fst.line and snd.char > fst.char)
	end,
	__le = function(fst, snd)
		return fst < snd or fst == snd
	end,
	__eq = function(fst, snd)
		return (snd.line == fst.line and snd.char == fst.char)
	end,
	__tostring = function(self)
		return "in file " .. self.sourceid .. ", line " .. self.line .. " character " .. self.char
	end,
}

local function element(kind, pattern)
	return Ct(V "anchor" * Cg(Cc(kind), "kind") * pattern)
end

local function symbol(value)
	return element("symbol", Cg(value, "str"))
end

local function space_tokens(pattern)
	local token_spacer = S "\t " ^ 0
	return pattern * token_spacer
end

local function list(pattern)
	return element("list", Cg(Ct(space_tokens(pattern)), "elements") * V "endpos")
end

local function create_literal(elements)
	local val = {}

	for _, v in ipairs(elements) do
		for char in v:gmatch "." do
			table.insert(val, string.byte(char))
		end
	end

	local longstring_val = {
		anchor = elements.anchor,
		kind = "literal",
		literaltype = "bytes",
		val = val,
	}

	return longstring_val
end

local grammar = P {
	"ast",
	ast = V "foreward" * V "file",

	-- shouldn't be used except in cases where the line/indentation is/does not matter
	wsp = lpeg.S "\t\n\r ",

	-- initializes empty capture groups at the start, remember to update when tracking new things!
	foreward = Cg(P "" / function(_)
		return { 0 }
	end, "indent_level"),

	-- every time there's a newline, get it's position. construct a named group with the position
	-- of the latest (numbered) newline
	-- Cmt because of precedence requirements
	newline = P "\r" ^ 0 * P "\n",

	-- either match the newline or match the beginning of the file
	filestart = Cmt(Cp(), function(_, _, mypos)
		return mypos == 1
	end),

	-- used by every element
	-- TODO: make this propogate errors back up the stack
	anchor = Cg(Cp(), "anchor"),
	endpos = Cg(Cp(), "endpos"),

	count_tabs = Cmt(Cp() * C(S "\t " ^ 1), function(_, _, anchor, indentstring)
		-- only tabs are allowed
		-- tabs and spaces must not be interleaved - tabs must happen before spaces.
		-- TODO: make nice errors in here

		local numtabs = 0

		for i = 1, #indentstring do
			local char = indentstring:sub(i, i)
			local lookbehind_char = indentstring:sub(i - 1, i - 1)

			if (char == "\t") and (lookbehind_char == " ") then
				print("error at ", anchor, ": tabs and spaces must not be interspersed")
				return false
			elseif char == "\t" then
				numtabs = numtabs + 1
			end
		end

		return true, numtabs
	end),

	-- an indented block which may have indents and dedents, so long as those indents
	-- are subordinate to the initial indent
	subordinate_indent = Cmt(Cb("indent_level") * V "count_tabs", function(_, _, prev_indent, this_indent)
		local norm_tab_level = this_indent - (prev_indent[#prev_indent] + 1)
		local norm_tabs = string.rep("\t", norm_tab_level)

		return this_indent > prev_indent[#prev_indent], norm_tabs
	end),

	longstring_body = C((V "unicode_escape" + (1 - (V "newline" + V "splice"))) ^ 1),
	longstring_newline = (
		(V "newline" * Cc("\n") * ((Cs(V "subordinate_indent") * V "longstring_body") + (S "\t " ^ 0 * #V "newline")))
		+ V "longstring_body"
	),
	longstring_literal = Ct(V "anchor" * (V "longstring_body" + V "longstring_newline") ^ 1) / create_literal,

	longstring = element(
		"string",
		P '""""' * Cg(Ct((V "longstring_literal" + V "splice") ^ 0), "elements") * V "endpos"
	),

	comment_body = C((1 - V "newline") ^ 1),
	comment = element(
		"comment",
		P "#"
			* Cg(
				Cs(
					V "comment_body" ^ -1
						* (V "newline" * ((V "subordinate_indent" * V "comment_body") + (S "\t " ^ 0 * #V "newline")))
							^ 0
				),
				"val"
			)
	),

	-- numbers are limited, they are not bignums, they are standard lua numbers. scopes shares the problem of files not having arbitrary precision
	-- so it probably doesn't matter.
	number = element("literal", Cg((V "float_special" + V "hex" + V "big_e") / tonumber, "val") * V "types"),
	types = Cg(
		(P ":" * C((S "iu" * (P "8" + P "16" + P "32" + P "64")) + (P "f" * (P "32" + P "64")))) + P "" / "f64",
		"literaltype"
	),
	digit = R("09") ^ 1,
	hex_digit = (V "digit" + R "AF" + R "af") ^ 1,
	decimal = S "-+" ^ -1 * V "digit" * (P "." * V "digit") ^ -1,
	hex = S "+-" ^ -1 * P "0x" * V "hex_digit" * (P "." * V "hex_digit") ^ -1,
	big_e = V "decimal" * (P "e" * V "decimal") ^ -1,
	float_special = P "+inf" + P "-inf" + P "nan",

	symbol = symbol((1 - (S "#;()[]{}," + V "wsp")) ^ 1),

	-- probably works but it doesn't have complex tests
	splice = P "${" * V "naked_list" * P "}",
	escape_chars = Cs(P [[\\]] / [[\]] + P [[\"]] / [["]] + P [[\n]] / "\n" + P [[\r]] / "\r" + P [[\t]] / "\t"),
	unicode_escape = P "\\u" * (V "hex_digit") ^ 4 ^ -4,

	-- for now, longstrings are not going to automatically translate \n into the escape character
	string_literal = Ct(
		V "anchor" * (V "escape_chars" + V "unicode_escape" + C(1 - (S [["\]] + V "newline" + V "splice"))) ^ 1
	) / create_literal,

	-- this doesn't work yet
	string = element("string", P '"' * Cg(Ct((V "string_literal" + V "splice") ^ 0), "elements") * P '"' * V "endpos"),

	tokens = space_tokens(
		V "comment" + V "function_call" + V "paren_list" + V "longstring" + V "string" + V "number" + V "symbol"
	),
	token_spacer = S "\t " ^ 0,

	-- LIST SEPARATOR BEHAVIOR IS NOT CONSISTENT BETWEEN BRACED AND NAKED LISTS
	permitted_paren_tokens = (
		(space_tokens(P [[\]]) * V "naked_list") -- \ escape char enters naked list mode from inside a paren list. there's probably an edge case here, indentation is going to be wacky
		+ V "tokens"
		+ V "newline"
		+ S "\t " ^ 1
	),
	base_paren_body = list(V "permitted_paren_tokens" ^ 1 * P ";") -- ; control character splits list-up-to-point into child list
		+ V "permitted_paren_tokens",

	-- the internal of a paren should be
	-- you can have list separators, that put everything before it into it's own sublist
	-- you can have commas. single token comma separated values are interpreted as if the comma was not there.
	-- BUT if there are multiple tokens in a comma slot, the tokens are placed into a sub list.
	-- backslash escapes into a naked list, at the root indentation level.
	-- if you have no commas in a list, elements in that list should not be placed into a sublist as if they were the end token.

	-- breaks paren body into comma sequence, should accept any individual paren_body or comma separated list
	comma_sep_paren_body = ((list(V "base_paren_body" ^ 2) + V "base_paren_body") * V "token_spacer" * P "," * V "token_spacer")
			^ 1
		* (list(V "base_paren_body" ^ 2) + V "base_paren_body"),

	match_paren_open = Cg(C(P "("), "bracetype")
		+ (Cg(C(P "["), "bracetype") * symbol(Cc("braced_list")))
		+ (Cg(C(P "{"), "bracetype") * symbol(Cc("curly-list"))),
	match_paren_close = Cmt(Cb("bracetype") * C(S "])}"), function(_, _, bracetype, brace)
		local matches = {
			["("] = ")",
			["["] = "]",
			["{"] = "}",
		}
		return matches[bracetype] == brace
	end),
	paren_body = V "comma_sep_paren_body" + V "base_paren_body" ^ 1,
	paren_list = list(V "match_paren_open" * V "paren_body" ^ 0 * V "match_paren_close"),

	-- subtly different from the base case
	-- if there's a set of arguments provided that aren't comma separated, they are automatically interpreted as a child list
	-- the base case will interpret such a thing as part of the normal list
	function_call = list(V "symbol" * P "(" * (V "comma_sep_paren_body" + V "base_paren_body") * P ")"),

	empty_line = V "newline" * space_tokens(P "") * #(V "newline" + -1),

	file = list(
		(
			(V "tokens" * (V "newline" + -1) * V "isdedent")
			+ (V "naked_list_line" ^ -1 * V "newline" * V "isdedent")
			+ (V "naked_list")
		) ^ 1
	) * -1,

	naked_list_line = (list(V "tokens" ^ 0 * space_tokens(P ";"))) ^ 1 * V "naked_list" ^ 0,
	naked_list = list( -- escape char terminates current list
		((V "naked_list_line" + V "tokens" ^ 1) ^ 1)
			* (V "empty_line" ^ 1 + (V "newline" * V "indent" * (((list(V "tokens" * space_tokens(P ";")) + V "tokens") * ((#(V "newline" * V "isdedent") * V "dedent") + (-P(
					1
				)))) + (V "naked_list" * V "dedent"))))
				^ 0
	),

	indent = Cg(
		Cmt(Cb("indent_level") * V "count_tabs", function(body, position, prev_indent, this_indent)
			if this_indent == nil then
				this_indent = 0
			end

			assert(prev_indent)
			assert(this_indent)

			if this_indent > prev_indent[#prev_indent] then
				table.insert(prev_indent, this_indent)

				return true, prev_indent
			else
				return false
			end
		end),
		"indent_level"
	),

	-- SIMPLIFYING ASSUMPTIONS:
	-- I can assume no more than one layer of indent at a time
	dedent = Cg(
		Cmt(Cb("indent_level"), function(body, position, prev_indent, this_indent)
			table.remove(prev_indent, #prev_indent)
			return true, prev_indent
		end),
		"indent_level"
	),

	isdedent = Cmt(Cb("indent_level") * V "count_tabs" ^ 0, function(body, position, prev_indent, this_indent)
		if this_indent == nil then
			this_indent = 0
		end

		assert(prev_indent)
		assert(this_indent)

		return this_indent <= prev_indent[#prev_indent]
	end),
}

local newlinegetter = P {
	"newlines",
	body = (1 - S "\r\n") ^ 1,
	newline = P "\r" ^ 0 * P "\n",
	newlines = Ct(Cp() * (V "body" + (V "newline" * Cp())) ^ 0),
}

local function create_anchor(anchor, newlines, cursor, sourceid)
	local line_num = cursor

	while (line_num + 1 <= #newlines) and (anchor >= newlines[line_num + 1]) do
		line_num = line_num + 1
	end
	local newanchor = {
		line = line_num,
		char = anchor - newlines[line_num] + 1,
		sourceid = sourceid,
	}
	setmetatable(newanchor, anchor_mt)

	return newanchor, line_num
end

local function correct_anchors(ast, newlines, cursor, sourceid)
	local revised_ast = ast
	local line_num = cursor

	assert(ast.anchor)
	revised_ast.anchor, line_num = create_anchor(ast.anchor, newlines, line_num, sourceid)
	if ast.kind == "list" or ast.kind == "string" then
		for i, v in ipairs(ast.elements) do
			revised_ast.elements[i], line_num = correct_anchors(v, newlines, line_num, sourceid)
		end

		revised_ast.endpos, line_num = create_anchor(ast.endpos, newlines, line_num, sourceid)
	end

	return revised_ast, line_num
end

local function parse(input, filename)
	assert(filename)
	local newline_list = lpeg.match(newlinegetter, input)
	local initial_ast = lpeg.match(grammar, input)

	local file_endpos = create_anchor(initial_ast.endpos, newline_list, #newline_list, filename)
	local revised_ast = correct_anchors(initial_ast, newline_list, 1, filename)
	revised_ast.endpos = file_endpos

	return revised_ast
end

return { parse = parse }
