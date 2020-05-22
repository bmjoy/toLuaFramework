PlayerProxy = class(Proxy)

function PlayerProxy:ctor()
    self.OnSpawn = {}
end

function PlayerProxy:OnRegister()
    self:super("OnRegister")
    LuaAddressables.LoadGameObjectAsync("Jump_Jump/Player", PlayerProxy, self, "Spawn")
end

function PlayerProxy:OnRemove()
    self:super("OnRemove")
end

function PlayerProxy:Spawn(prefab)
    self.player = GameObject.Instantiate(prefab)
    self.rigidbody = self.player:GetComponent("Rigidbody")
    self.head = self.player.transform:Find("Head")
    self.body = self.player.transform:Find("Body")

    if self.OnSpawn then
        for k, v in ipairs(self.OnSpawn) do
            v:Invoke()
        end
    end
end

return PlayerProxy