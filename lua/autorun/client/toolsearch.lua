local favorites = util.JSONToTable(file.Read("tools_favorites.txt", "DATA") or "{}") or {}
local cl_toolsearch_autoselect = CreateClientConVar("cl_toolsearch_autoselect", "1")
local cl_toolsearch_favoritesonly = CreateClientConVar("cl_toolsearch_favoritesonly", "0")
local cl_toolsearch_favoritestyle = CreateClientConVar("cl_toolsearch_favoritestyle", "2")
hook.Add("PostReloadToolsMenu", "ToolSearch", function()
	local toolPanel = g_SpawnMenu.ToolMenu.ToolPanels[1]
	local divider = toolPanel.HorizontalDivider
	if not IsValid(divider) then return error("Something is modifying the spawnmenu and is preventing the Tool Search add-on from working!") end
	local list = toolPanel.List
	-- Hijack the tool list's left side
	local panel = vgui.Create("EditablePanel", divider)
	list:SetParent(panel)
	list:Dock(FILL)
	divider:SetLeft(panel)
	local textEntry = panel:Add("EditablePanel")
	textEntry:Dock(TOP)
	textEntry:DockMargin(0, 0, 0, 2)
	textEntry:SetZPos(0)
	textEntry:SetTall(20)
	local search = textEntry:Add("DTextEntry")
	search:Dock(FILL)
	search:DockMargin(0, 0, 2, 0)
	search:SetPlaceholderText("#spawnmenu.quick_filter")
	search:SetUpdateOnType(true)
	-- Shared filter. Applied on user input AND re-applied after the game's own
	-- tool-visibility pass (see the UpdateToolDisabledStatus override below):
	-- as of the July 2026 "hide disabled tools" update, that pass re-shows every
	-- tool on a 1.5s timer and would otherwise stomp the favorites/search filter.
	-- autoSelect is only allowed on real user input, never on the periodic re-apply.
	local function applyFilter(allowAutoSelect)
		local needle = search:GetValue():lower()
		local autoSelect = allowAutoSelect and cl_toolsearch_autoselect:GetBool()
		local favoritesOnly = cl_toolsearch_favoritesonly:GetBool()
		local showAll = not favoritesOnly
		local i = 0
		for _, category in next, list.pnlCanvas:GetChildren() do
			local hidden = 0
			for k, item in next, category:GetChildren() do
				if item == category.Header then continue end
				local haystack = language.GetPhrase(item:GetText()):lower()
				if not item._disabledHidden and haystack:match(needle) and (showAll or favorites[item.Name]) then -- respect the game's hide-disabled-tools setting
					item:SetVisible(true)
					if autoSelect and needle ~= "" then
						i = i + 1
						if i == 1 then item:DoClick() end
					end
				else
					item:SetVisible(false)
					hidden = hidden + 1
				end
			end

			if hidden >= #category:GetChildren() - 1 then
				category:SetVisible(false)
			else
				category:SetVisible(true)
			end

			category:InvalidateLayout()
			list.pnlCanvas:InvalidateLayout()
		end
	end

	function search:OnValueChange()
		applyFilter(true)
	end

	local clear = textEntry:Add("DButton")
	clear:Dock(RIGHT)
	clear:SetWide(16 + 4)
	clear:SetText("")
	clear:SetTooltip("Press to clear")
	function clear:DoClick()
		search:SetValue("")
	end

	local cross = Material("icon16/cross.png")
	function clear:Paint(w, h)
		derma.SkinHook("Paint", "Button", self, w, h)
		surface.SetMaterial(cross)
		surface.SetDrawColor(Color(255, 255, 255))
		surface.DrawTexturedRect(w * 0.5 - 16 * 0.5, h * 0.5 - 16 * 0.5, 16, 16)
	end

	-- Horizontal gap between a checkbox and its label, shared by both rows below.
	-- Tuned between the DCheckBoxLabel default (9, too airy) and a tight 4.
	local labelGap = 6
	local toggleFavorites = panel:Add("EditablePanel")
	toggleFavorites:Dock(TOP)
	toggleFavorites:SetZPos(1)
	toggleFavorites:SetTall(21)
	local check = toggleFavorites:Add("DCheckBoxLabel")
	check:Dock(FILL)
	check:DockMargin(0, 0, 0, 1)
	check:SetConVar("cl_toolsearch_favoritesonly")
	check:SetText("Favorites Only")
	check:SetBright(true)
	function check:OnChange()
		applyFilter(true)
	end

	-- DCheckBoxLabel hardcodes a 9px checkbox/label gap; pull its label in to
	-- labelGap so it matches the re-homed "Hide disabled tools" row below.
	local baseCheckLayout = check.PerformLayout
	function check:PerformLayout(w, h)
		baseCheckLayout(self, w, h)
		local _, ly = self.Label:GetPos()
		self.Label:SetPos(self.Button:GetWide() + labelGap, ly)
	end

	-- Re-home the game's own "Hide disabled tools" checkbox (added in the July 2026
	-- update). Hijacking the divider's left side detaches it from view, so we reparent
	-- the shipped panel right below "Favorites Only". Reusing it keeps its convar binding
	-- and its OnChange refresh wiring; it ships label-less (tooltip only), so we add one.
	local hideDisabled = toolPanel.HideDeactivated
	if IsValid(hideDisabled) then
		local toggleDisabled = panel:Add("EditablePanel")
		toggleDisabled:Dock(TOP)
		toggleDisabled:SetZPos(2)
		toggleDisabled:SetTall(21)
		hideDisabled:SetParent(toggleDisabled)
		hideDisabled:SetWide(15)
		-- The game docks this RIGHT next to the search bar; re-dock it LEFT so it
		-- lines up under the "Favorites Only" checkbox. The vertical margins centre
		-- the 15px box within the 21px row.
		hideDisabled:Dock(LEFT)
		-- labelGap right margin puts its label at the same offset as the row above.
		hideDisabled:DockMargin(0, 2, labelGap, 4)
		local hideLabel = toggleDisabled:Add("DLabel")
		hideLabel:Dock(FILL)
		hideLabel:SetText(language.GetPhrase("spawnmenu.tools.hide_disabled"))
		hideLabel:SetBright(true)
		hideLabel:SetMouseInputEnabled(true)
		function hideLabel:OnMousePressed()
			hideDisabled:Toggle()
		end
	end

	-- Setup the favorites display system
	-- list:SetSkin("Default")
	local star = Material("icon16/star.png")
	local smallStar = Material("icon16/bullet_star.png")
	-- Sampled live (per-skin) so switching Derma skins updates the favorite tint.
	-- (260, 388) lies inside SKIN.tex.CategoryList.Outer — the spawnmenu category background.
	local lightnessCache = {}
	local function getSkinLightness(skin)
		if not skin then return 1 end
		local cached = lightnessCache[skin]
		if cached ~= nil then return cached end
		local tex = skin.GwenTexture
		local v = 1
		if tex then
			local _, _, lv = ColorToHSV(tex:GetColor(260, 388))
			v = lv
		end

		lightnessCache[skin] = v
		return v
	end

	local function setupFavorites()
		for _, category in next, list.pnlCanvas:GetChildren() do
			for k, item in next, category:GetChildren() do
				if item == category.Header then continue end
				item.Favorite = favorites[item.Name]
				if not item._Paint or not item._UpdateColours then
					item._Paint = item.Paint
					item._UpdateColours = item.UpdateColours
					function item:Paint(w, h)
						local ret = self:_Paint(w, h)
						if self.Favorite then
							local style = cl_toolsearch_favoritestyle:GetInt()
							if style ~= 1 then
								surface.SetMaterial(style == 3 and smallStar or star)
								surface.SetDrawColor(Color(255, 255, 255))
								surface.DrawTexturedRect(w - 16, h * 0.5 - 8, 16, 16)
							else
								if self:IsDown() or self.m_bSelected then return ret end
								local v = getSkinLightness(self:GetSkin())
								local favBtnColor = HSVToColor(50, 0.33, v > 0.5 and 0.95 or 0.4)
								local altLineAlpha = self.AltLine and 90 or 0
								surface.SetDrawColor(Color(favBtnColor.r, favBtnColor.g, favBtnColor.b, 255 - altLineAlpha))
								surface.DrawRect(0, 0, w, h)
							end
						end
						return ret
					end

					function item:UpdateColours(skin)
						-- if style ~= 1 then return self:_UpdateColours(skin) end
						if self.Favorite then
							local textColor = getSkinLightness(skin) > 0.5 and color_black or color_white
							local altLineAlpha = self.AltLine and 15 or 0
							if self.Depressed or self.m_bSelected then return self:_UpdateColours(skin) end
							if self.Hovered then return self:SetTextStyleColor(Color(textColor.r, textColor.g, textColor.b, 255 - altLineAlpha)) end
							return self:SetTextStyleColor(Color(textColor.r, textColor.g, textColor.b, 245 - altLineAlpha))
						else
							return self:_UpdateColours(skin)
						end
					end
				end

				function item:DoRightClick(w, h)
					self.Favorite = not self.Favorite
					self:ApplySchemeSettings()
					-- the hax
					timer.Simple(0, function() self:ApplySchemeSettings() end)
					favorites[self.Name] = self.Favorite
					file.Write("tools_favorites.txt", util.TableToJSON(favorites))
					surface.PlaySound("garrysmod/content_downloaded.wav")
				end

				category:InvalidateLayout()
				list.pnlCanvas:InvalidateLayout()
			end
		end
	end

	setupFavorites()
	-- The game re-runs its own tool-visibility pass on a 1.5s timer (added July 2026),
	-- which re-shows every tool and clobbers our filter. Re-apply ours right after it.
	if toolPanel.UpdateToolDisabledStatus then
		local baseUpdate = toolPanel.UpdateToolDisabledStatus
		function toolPanel:UpdateToolDisabledStatus()
			baseUpdate(self)
			applyFilter(false)
		end
	end

	-- Apply once now so opening the menu with a filter already active is honoured
	-- immediately, instead of waiting for the first typed keystroke.
	applyFilter(false)
	-- Let's completely hide the vanilla one (at the end, in case something breaks...)
	toolPanel.SearchBar:SetVisible(false)
end)

-- Config
language.Add("favorite_style_1", "1 - Color Change")
language.Add("favorite_style_2", "2 - Star Icon")
language.Add("favorite_style_3", "3 - Small Star Icon")
hook.Add("PopulateToolMenu", "ToolSearch", function()
	spawnmenu.AddToolMenuOption("Utilities", "User", "ToolSearch", "Tool Search", "", "", function(pnl)
		pnl:AddControl("Header", {
			Description = "Configure the Tool Search's behavior."
		})

		pnl:AddControl("CheckBox", {
			Label = "Auto-Select",
			Command = "cl_toolsearch_autoselect",
		})

		pnl:ControlHelp("If enabled, this will select the top most tool automatically when you do a search query.")
		pnl:AddControl("Header", {
			Description = "Right-click tools to make them your favorites!"
		})

		pnl:AddControl("ListBox", {
			Options = {
				["#favorite_style_1"] = {
					cl_toolsearch_favoritestyle = 1
				},
				["#favorite_style_2"] = {
					cl_toolsearch_favoritestyle = 2
				},
				["#favorite_style_3"] = {
					cl_toolsearch_favoritestyle = 3
				},
			},
			Label = "Favorite Tool Style"
		})
	end)
end)

-- RunConsoleCommand("spawnmenu_reload")
