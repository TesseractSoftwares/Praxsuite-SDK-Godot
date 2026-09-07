## A topic - a namespace of buses.
##
## Prax.bus.topic("office").channel("hq") is the bus "office:hq".
##
## Topics are admin-declared workspace configuration, not something a client invents: the hub
## refuses a bus key whose topic was never declared, which is what stops another game's client
## squatting in your namespace. Declare one in the portal under API Gateway / Event Bus and pick
## its access rule there.
class_name PraxTopic
extends RefCounted

## The topic segment, already lowercased the way the server folds it.
var key: String = ""

var _bus: Object = null


func _init(bus: Object, p_key: String) -> void:
	_bus = bus
	key = p_key


## The bus for one instance of this topic. Returns a PraxChannel, or a PraxError for a key the
## server would refuse.
func channel(instance: String) -> Variant:
	return _bus.channel(key + ":" + instance)
