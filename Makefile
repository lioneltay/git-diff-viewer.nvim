PLENARY_DIR = deps/plenary.nvim

$(PLENARY_DIR):
	mkdir -p deps
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)

.PHONY: test test-unit test-integration
test: $(PLENARY_DIR)
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

test-unit: $(PLENARY_DIR)
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/unit/ {minimal_init = 'tests/minimal_init.lua'}"

test-integration: $(PLENARY_DIR)
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/integration/ {minimal_init = 'tests/minimal_init.lua'}"
