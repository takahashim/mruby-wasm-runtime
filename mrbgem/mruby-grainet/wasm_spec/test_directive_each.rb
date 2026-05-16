Spec.describe "data-each / data-key directives (grainet-cli codegen target)" do
  Spec.assert "flat list: bind_list + template clones the iteration body and reacts" do
    doc = JS.global[:document]
    body = doc[:body]
    # Synthetic template + container exactly as grainet-cli would emit.
    body[:innerHTML] = <<~HTML
      <template data-template="gn-each-todo-list-g0"><li><span data-ref="gT"></span></li></template>
      <div data-component="TodoList"><ul data-ref="g0"></ul></div>
    HTML

    todo_class = Class.new do
      attr_reader :id, :title
      define_method(:initialize) do |id:, title:|
        @id = id
        @title = title
      end
    end

    klass = Class.new(Grainet::Component) do
      attr_reader :todos
      define_method(:setup) do
        @todos = signal(
          [
            todo_class.new(id: "a", title: "first"),
            todo_class.new(id: "b", title: "second"),
          ],
        )
      end
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        bind_list refs.g0, @todos, key: ->(it) { it.id },
                  template: "gn-each-todo-list-g0" do |it, t|
          bind_template_hook__each_g0(it, t)
        end
      end
      define_method(:bind_template_hook__each_g0) do |it, t|
        bind t.refs.gT, text: computed { it.title }
      end
    end
    klass.include(bindings)

    Grainet.register("TodoList", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    titles = -> {
      list = doc.call(:querySelectorAll, "[data-ref=\"gT\"]")
      (0...list[:length].to_i).map { |i| list[i][:textContent].to_s }
    }
    Spec.assert_equal ["first", "second"], titles.call

    # Append a new item — bind_list reconciles, adds one DOM node.
    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-component=\"TodoList\"]"))
    inst.todos.value = inst.todos.value + [todo_class.new(id: "c", title: "third")]
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal ["first", "second", "third"], titles.call

    # Reorder by key — existing nodes move, no new <li> created.
    inst.todos.value = [
      todo_class.new(id: "c", title: "third"),
      todo_class.new(id: "a", title: "first"),
      todo_class.new(id: "b", title: "second"),
    ]
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal ["third", "first", "second"], titles.call

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end

  Spec.assert "data-on inside data-each passes the item to the handler" do
    doc = JS.global[:document]
    body = doc[:body]
    body[:innerHTML] = <<~HTML
      <template data-template="gn-each-todo-list-g0"><li><button data-ref="gB">x</button></li></template>
      <div data-component="TodoList"><ul data-ref="g0"></ul></div>
    HTML

    todo_class = Class.new do
      attr_reader :id
      define_method(:initialize) { |id:| @id = id }
    end

    klass = Class.new(Grainet::Component) do
      attr_reader :todos, :removed
      define_method(:setup) do
        @todos = signal([todo_class.new(id: "x"), todo_class.new(id: "y")])
        @removed = []
      end
      define_method(:remove) do |item, _ev|
        @removed << item.id
      end
    end
    bindings = Module.new do
      define_method(:bind_template_hook) do
        bind_list refs.g0, @todos, key: ->(it) { it.id },
                  template: "gn-each-todo-list-g0" do |it, t|
          bind_template_hook__each_g0(it, t)
        end
      end
      define_method(:bind_template_hook__each_g0) do |it, t|
        t.refs.gB.on(:click) { |ev| remove(it, ev) }
      end
    end
    klass.include(bindings)

    Grainet.register("TodoList", klass)
    Grainet.start
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await

    inst = Grainet.find_for_element(doc.call(:querySelector, "[data-component=\"TodoList\"]"))
    buttons = doc.call(:querySelectorAll, "[data-ref=\"gB\"]")
    buttons[1].call(:click)
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
    Spec.assert_equal ["y"], inst.removed

    Grainet.reset!
    body[:innerHTML] = ""
    JS.eval_javascript("new Promise(r => setTimeout(r, 0))").await
  end
end
