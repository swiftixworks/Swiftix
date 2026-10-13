/// The functions of `sort` that call back into the program: `sort.Slice`
/// with its `less`, `sort.Sort` with its `Interface`, `sort.Search`.
///
/// They are Go text of the library, compiled with the program that uses
/// them (`GoSourceLibrary`). What each program prints is what Go 1.24.5
/// prints for it, and that includes the order equal elements end in under
/// the sorts that are not stable, and how often and with which indexes
/// `Less` and `Swap` are called: a program can see both. A message pinned
/// alone is one this dialect words in its own way.

@testable import SwiftixGo
import SwiftixGoRuntime
import Testing

@testable import Swiftix
@testable import SwiftixGoTool

@Suite("Go sort")
struct GoSortTests: GoTestHarness {

    /// The first error of compiling `body` as the body of `func main`, as
    /// `line:column: message`: what Go prints after the name of the file.
    private func firstError(
        _ body: String, imports: [String] = ["fmt"], declarations: String = ""
    ) -> String? {
        do {
            _ = try GoCompiler.compile(sources: [
                GoSourceFile(
                    path: "main.go",
                    text: goMainSource(body, imports: imports, declarations: declarations))
            ])
            return nil
        } catch let diagnostic as GoDiagnostic {
            return String(diagnostic.description.dropFirst("main.go:".count))
        } catch {
            return String(describing: error)
        }
    }

    /// The `less` function is the program's; the elements are exchanged
    /// without knowing their type.
    @Test func sliceSortsASliceOfAnyElementType() throws {
        #expect(
            try runGoMain(
                """
                xs := []int{3, 1, 2}
                sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })
                fmt.Println(xs)
                people := []person{person{"al", 30}, person{"bo", 25}, person{"cy", 30}, person{"di", 25}, person{"ed", 41}}
                sort.Slice(people, func(i, j int) bool { return people[i].age < people[j].age })
                fmt.Println(people)
                var empty []string
                sort.Slice(empty, func(i, j int) bool { return empty[i] < empty[j] })
                fmt.Println(empty == nil, len(empty))
                whole := []int{9, 8, 7, 6, 5, 4, 3, 2, 1, 0}
                window := whole[2:7]
                sort.Slice(window, func(i, j int) bool { return window[i] < window[j] })
                fmt.Println(whole, window)
                var boxed interface{} = []string{"b", "c", "a"}
                sort.Slice(boxed, func(i, j int) bool { s := boxed.([]string); return s[i] < s[j] })
                fmt.Println(boxed)
                pointers := []*person{&person{"z", 1}, &person{"y", 2}, &person{"x", 3}}
                sort.Slice(pointers, func(i, j int) bool { return pointers[i].name < pointers[j].name })
                for _, p := range pointers {
                    fmt.Print(p.name, p.age, " ")
                }
                grid := [][]int{[]int{3, 1}, []int{1, 2}, []int{2, 0}}
                sort.Slice(grid, func(i, j int) bool { return grid[i][0] < grid[j][0] })
                bytes := []byte("hello")
                sort.Slice(bytes, func(i, j int) bool { return bytes[i] < bytes[j] })
                var names ranking = []string{"bob", "al", "christine"}
                sort.Slice(names, func(i, j int) bool { return len(names[i]) < len(names[j]) })
                fmt.Println(grid, string(bytes), names)
                counts := map[string]int{"x": 3, "y": 1, "z": 2}
                keys := make([]string, 0, len(counts))
                for key := range counts {
                    keys = append(keys, key)
                }
                sort.Slice(keys, func(i, j int) bool { return counts[keys[i]] < counts[keys[j]] })
                fmt.Println(keys)
                """,
                imports: ["fmt", "sort"],
                declarations: """
                    type person struct {
                        name string
                        age  int
                    }

                    type ranking []string
                    """)
                == """
                [1 2 3]
                [{bo 25} {di 25} {al 30} {cy 30} {ed 41}]
                true 0
                [9 8 3 4 5 6 7 2 1 0] [3 4 5 6 7]
                [a b c]
                x3 y2 z1 [[1 2] [2 0] [3 1]] ehllo [al bob christine]
                [y z x]

                """)
    }

    /// And `SliceIsSorted` says whether a slice is in the order of a `less`.
    @Test func sliceStableKeepsEqualElementsInTheirOrder() throws {
        #expect(
            try runGoMain(
                """
                people := []person{person{"al", 30}, person{"bo", 25}, person{"cy", 30}, person{"di", 25}, person{"ed", 41}, person{"fy", 25}}
                sort.SliceStable(people, func(i, j int) bool { return people[i].age < people[j].age })
                fmt.Println(people)
                sort.SliceStable(people, func(i, j int) bool { return people[i].name > people[j].name })
                fmt.Println(people)
                fmt.Println(sort.SliceIsSorted(people, func(i, j int) bool { return people[i].name > people[j].name }),
                    sort.SliceIsSorted(people, func(i, j int) bool { return people[i].age < people[j].age }),
                    sort.SliceIsSorted([]int{}, func(i, j int) bool { return true }))
                """,
                imports: ["fmt", "sort"],
                declarations: """
                    type person struct {
                        name string
                        age  int
                    }
                    """)
                == """
                [{bo 25} {di 25} {fy 25} {al 30} {cy 30} {ed 41}]
                [{fy 25} {ed 41} {di 25} {cy 30} {bo 25} {al 30}]
                true false true

                """)
    }

    /// `sort.Interface` is an interface of the program like any other, and
    /// `sort.IntSlice`, `sort.StringSlice`, and what `sort.Reverse` returns are
    /// types that implement it.
    @Test func sortTakesAnyTypeWithTheThreeMethods() throws {
        #expect(
            try runGoMain(
                #"""
                words := []string{"ccc", "a", "bb", "dddd", "ee", "f"}
                sort.Sort(byLength(words))
                fmt.Println(words)
                sort.Stable(byLength(words))
                fmt.Println(words, sort.IsSorted(byLength(words)))
                sort.Sort(sort.Reverse(byLength(words)))
                fmt.Println(words, sort.IsSorted(byLength(words)), sort.IsSorted(sort.Reverse(byLength(words))))
                ints := []int{5, 2, 8, 1}
                sort.Sort(sort.IntSlice(ints))
                fmt.Println(ints)
                sort.Sort(sort.Reverse(sort.IntSlice(ints)))
                fmt.Println(ints)
                strs := sort.StringSlice{"q", "b", "z"}
                strs.Sort()
                fmt.Println(strs, len(strs), strs.Len(), strs.Less(0, 1), strs.Search("q"))
                var data sort.Interface = sort.IntSlice{3, 1, 2}
                sort.Stable(data)
                fmt.Println(data, data.Len(), sort.IntSlice{1, 5, 9}.Search(5))
                fmt.Printf("%T %T %T %T\n", strs, sort.IntSlice(ints), sort.Reverse(strs), data)
                fmt.Printf("%v %+v\n", sort.Reverse(data), sort.Reverse(data))
                var none sort.Interface
                fmt.Println(none == nil)
                var held interface{} = strs
                _, isInterface := held.(sort.Interface)
                held = words
                _, isNot := held.(sort.Interface)
                fmt.Println(isInterface, isNot)
                """#,
                imports: ["fmt", "sort"],
                declarations: """
                    type byLength []string

                    func (b byLength) Len() int           { return len(b) }
                    func (b byLength) Less(i, j int) bool { return len(b[i]) < len(b[j]) }
                    func (b byLength) Swap(i, j int)      { b[i], b[j] = b[j], b[i] }
                    """)
                == """
                [a f bb ee ccc dddd]
                [a f bb ee ccc dddd] true
                [dddd ccc bb ee a f] false true
                [1 2 5 8]
                [8 5 2 1]
                [b q z] 3 3 true 1
                [1 2 3] 3 1
                sort.StringSlice sort.IntSlice *sort.reverse sort.IntSlice
                &{[1 2 3]} &{Interface:[1 2 3]}
                true
                true false

                """)
    }

    /// `Search`, `Find`, and the searches of a sorted slice.
    @Test func searchBisectsWithAFunctionOfTheProgram() throws {
        #expect(
            try runGoMain(
                """
                fmt.Println(sort.Search(100, func(i int) bool { return i*i >= 50 }), sort.Search(0, func(i int) bool { return true }),
                    sort.Search(5, func(i int) bool { return false }))
                ints := []int{1, 3, 5, 7}
                fmt.Println(sort.SearchInts(ints, 5), sort.SearchInts(ints, 4), sort.SearchInts(ints, 99), sort.SearchInts(nil, 1))
                fmt.Println(sort.SearchStrings([]string{"a", "c", "e"}, "d"), sort.SearchStrings([]string{"a", "c"}, "a"))
                calls := 0
                at, found := sort.Find(len(ints), func(i int) int {
                    calls++
                    return 7 - ints[i]
                })
                fmt.Println(at, found, calls)
                at, found = sort.Find(len(ints), func(i int) int { return 4 - ints[i] })
                fmt.Println(at, found)
                fmt.Println(sort.IntsAreSorted(ints), sort.IntsAreSorted([]int{2, 1}), sort.StringsAreSorted([]string{"a", "b"}),
                    sort.StringsAreSorted([]string{"b", "a"}))
                """,
                imports: ["fmt", "sort"])
                == "8 0 5\n2 2 4 0\n2 0\n3 true 3\n2 false\ntrue false true false\n")
    }

    /// Go's sorts are deterministic, and so is what a program sees of them:
    /// the number of calls of `Less` and `Swap`, the indexes of each call in
    /// order (summed up here), and the order equal elements end in. Every
    /// arrangement is sorted by `Sort`, by `Stable`, in reverse, and with a
    /// `Less` that is no order at all, which is what reaches the heapsort.
    @Test func theCallsOfLessAndSwapAreGos() throws {
        #expect(
            try runGoMain(
                """
                for _, n := range []int{0, 1, 2, 13, 50, 100} {
                    for shape := 0; shape < 9; shape++ {
                        base := input(n, shape)
                        a := &recorder{items: clone(base)}
                        sort.Sort(a)
                        b := &recorder{items: clone(base)}
                        sort.Stable(b)
                        c := &recorder{items: clone(base)}
                        sort.Sort(sort.Reverse(c))
                        d := &recorder{items: clone(base), bad: true}
                        sort.Sort(d)
                        e := &recorder{items: clone(base), bad: true}
                        sort.Stable(e)
                        fmt.Println(n, shape, a.calls, a.sum, digest(a.items), b.calls, b.sum, digest(b.items),
                            c.calls, c.sum, digest(c.items), d.calls, d.sum, digest(d.items), e.calls, e.sum, digest(e.items))
                    }
                }
                """,
                imports: ["fmt", "sort"],
                declarations: """
                    type item struct{ key, tag int }

                    // recorder is a sort.Interface that sums up every call it gets.
                    type recorder struct {
                        items []item
                        calls int
                        sum   int
                        bad   bool
                    }

                    func (r *recorder) Len() int { return len(r.items) }

                    func (r *recorder) Less(i, j int) bool {
                        r.calls++
                        r.sum = (r.sum*1000003 + i*31 + j + 7) & 0xfffffffffffff
                        if r.bad {
                            return (r.items[i].key*31+r.items[j].tag)%3 == 0
                        }
                        return r.items[i].key < r.items[j].key
                    }

                    func (r *recorder) Swap(i, j int) {
                        r.calls++
                        r.sum = (r.sum*1000003 + i*17 + j + 3) & 0xfffffffffffff
                        r.items[i], r.items[j] = r.items[j], r.items[i]
                    }

                    var seed = 12345

                    func next(n int) int {
                        seed = (seed*1103515245 + 12345) & 0x7fffffff
                        return (seed >> 8) % n
                    }

                    // input is n items in one of nine arrangements, most with many equal keys.
                    func input(n, shape int) []item {
                        items := make([]item, n)
                        choices := []int{1, 2, 3, 5, 10, 100, 1000000}
                        distinct := choices[next(7)]
                        for i := 0; i < n; i++ {
                            key := 0
                            switch shape {
                            case 0:
                                key = next(distinct)
                            case 1:
                                key = i
                            case 2:
                                key = n - i
                            case 3:
                                key = i % (distinct + 1)
                            case 4:
                                key = 7
                            case 5:
                                if i < n/2 {
                                    key = i
                                } else {
                                    key = n - i
                                }
                            case 6:
                                key = i
                                if next(50) == 0 {
                                    key = next(n + 1)
                                }
                            case 7:
                                key = (n - i) / (1 + next(3))
                            case 8:
                                key = (i / 7) % 5
                            }
                            items[i] = item{key, i}
                        }
                        return items
                    }

                    func clone(items []item) []item {
                        out := make([]item, len(items))
                        copy(out, items)
                        return out
                    }

                    func digest(items []item) int {
                        sum := 0
                        for _, it := range items {
                            sum = (sum*1000003 + it.key*131 + it.tag) & 0xfffffffffffff
                        }
                        return sum
                    }
                    """,
                machine: GoVirtualMachine(maximumInstructions: 12_000_000))
                == """
                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 4 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 6 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 7 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 8 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                1 0 0 0 1048 0 0 1048 0 0 1048 0 0 1048 0 0 1048
                1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                1 2 0 0 131 0 0 131 0 0 131 0 0 131 0 0 131
                1 3 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                1 4 0 0 917 0 0 917 0 0 917 0 0 917 0 0 917
                1 5 0 0 131 0 0 131 0 0 131 0 0 131 0 0 131
                1 6 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                1 7 0 0 131 0 0 131 0 0 131 0 0 131 0 0 131
                1 8 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                2 0 1 38 1 1 38 1 1 8 1 2 38000134 1000003 2 38000134 1000003
                2 1 1 38 132 1 38 132 2 8000044 132000396 1 38 132 1 38 132
                2 2 2 38000134 132000658 2 38000134 132000658 1 8 262000918 1 38 262000918 1 38 262000918
                2 3 1 38 132 1 38 132 2 8000044 132000396 1 38 132 1 38 132
                2 4 1 38 917003669 1 38 917003669 1 8 917003669 1 38 917003669 1 38 917003669
                2 5 1 38 132 1 38 132 2 8000044 132000396 1 38 132 1 38 132
                2 6 1 38 132 1 38 132 2 8000044 132000396 1 38 132 1 38 132
                2 7 2 38000134 1000265 2 38000134 1000265 1 8 262000787 2 38000134 1000265 2 38000134 1000265
                2 8 1 38 1 1 38 1 1 8 1 2 38000134 1000003 2 38000134 1000003
                13 0 43 1241062053668241 1537811041379236 82 2344412294425242 1958155215550148 55 1658733042776017 3803745444779368 39 3567727216132499 566879374777314 26 2994085411240814 324531313183106
                13 1 15 4417784425609060 4337228649371832 12 1480620276499088 4337228649371832 51 4398697344204871 3663095761039608 57 3769359250305970 1258503779273096 20 474757702403804 1581528608700664
                13 2 51 4325921873174599 3765510129220227 156 1849522116436304 3765510129220227 15 1360955168188514 2692173227616931 46 838851711855632 24853087599187 23 2766264388822170 224921366279611
                13 3 15 4417784425609060 4337228649371832 12 1480620276499088 4337228649371832 51 4398697344204871 3663095761039608 57 3769359250305970 1258503779273096 20 474757702403804 1581528608700664
                13 4 15 4417784425609060 2003140768258187 12 1480620276499088 2003140768258187 15 1360955168188514 2003140768258187 76 2410124964465336 2709917630343295 56 1394976480302896 2844224156444831
                13 5 49 798252059199508 995300084495361 74 4366439654423864 691359700587937 51 4116522403455548 1539556679142277 59 3333100470733267 4446999652823951 22 4340858537212024 725231992254057
                13 6 15 4417784425609060 4337228649371832 12 1480620276499088 4337228649371832 51 4398697344204871 3663095761039608 57 3769359250305970 1258503779273096 20 474757702403804 1581528608700664
                13 7 88 4266977989707582 1981571452675503 135 2584316603943670 1772688707925597 43 3918530557358887 4013245760521207 46 476986898956195 4227126143220373 21 2719430132558200 2848115614476077
                13 8 15 4417784425609060 4224328845917938 12 1480620276499088 4224328845917938 33 1237961905055346 1533028023837166 51 1359135520889869 1605691609601368 39 2541323975891682 1998836390844166
                50 0 323 1607211224653441 3726390693204698 605 3838283851479667 1820382916163244 314 1375264366242487 3969578370182996 317 3290202831395474 1006329531434538 234 89357385918143 2110563440888610
                50 1 61 367285576575689 2253480775856100 61 611594592316570 2253480775856100 86 864953099318108 3227639913579948 375 1739395866886920 3364446875442492 118 2483541642068423 848698641998196
                50 2 86 3729133884522714 1089307939499906 953 2867446986082756 1089307939499906 61 1724108350521845 1843998016317158 61 367285576575689 1843998016317158 61 611594592316570 1843998016317158
                50 3 61 367285576575689 2253480775856100 61 611594592316570 2253480775856100 86 864953099318108 3227639913579948 375 1739395866886920 3364446875442492 118 2483541642068423 848698641998196
                50 4 61 367285576575689 2461073861805005 61 611594592316570 2461073861805005 61 1724108350521845 2461073861805005 347 3240030794910938 835834271236595 412 1811296653048746 1129258514442989
                50 5 367 1336930553492409 3731721380693820 592 704668212075302 2635440931402668 361 732368012341097 767649889063556 229 227548831230847 328368186334860 169 3411660351972461 1915768042865712
                50 6 75 2916366635208951 3226502256116571 73 829353557440852 3226502256116571 100 3117141721923538 3640186951480809 352 156300322474868 3354328039711363 118 2483541642068423 344466335028635
                50 7 360 2810527237881717 3466320990564381 840 1031108701327619 1876651053691579 368 2262903473805379 701950776623615 150 160247777547488 540263101560161 189 1816506190583580 1801663994183671
                50 8 213 4074875729719606 1647367596522110 324 4017122279570922 4325391315647300 215 1195899199144942 1464737150100690 237 2812867402308437 3527621154797474 216 3854598413770223 3043519597863060
                100 0 372 2622495780791493 2352572322675254 776 550722290087505 3177983698087992 321 602721514581152 919591119659184 1059 2071620641779244 2770173737704910 513 3055167378580644 1913763683018480
                100 1 111 1537843005967510 2248074334583816 122 3864843332562968 2248074334583816 161 3770174666517208 1378322170779864 820 622978122527843 2335351033728632 338 2395346482615064 1166165888666928
                100 2 161 3904437524108382 3934809832470516 2147 3231037700423393 3934809832470516 111 863629355046960 2327635793859420 338 1913351933774934 1748105030671476 734 3567437930450861 1430396985918968
                100 3 111 1537843005967510 2248074334583816 122 3864843332562968 2248074334583816 161 3770174666517208 1378322170779864 820 622978122527843 2335351033728632 338 2395346482615064 1166165888666928
                100 4 111 1537843005967510 1907794305578314 122 3864843332562968 1907794305578314 111 863629355046960 1907794305578314 746 1202194321046364 554336229122234 1010 2598203775428874 2004178371823308
                100 5 909 4299622215631218 1012213556292322 1407 2353801378751810 2871592026434990 869 1124595007525749 2906924460950090 675 3302694569030790 1772500272005910 466 3317992891270865 1248050175535174
                100 6 111 1537843005967510 2248074334583816 122 3864843332562968 2248074334583816 161 3770174666517208 1378322170779864 820 622978122527843 2335351033728632 338 2395346482615064 1166165888666928
                100 7 795 2679729236987233 2172459074611228 1827 2705040380151204 650172820040458 829 2854707041350022 814354108288400 565 1873049257121674 4153168385908750 479 421756138626377 146708266315176
                100 8 470 2859398187307415 4259489413271528 867 2981156352223016 2052649611486232 800 3979262803563544 2996361761410598 761 3274152456849735 4356551148035258 579 1831454335586778 830165329962802

                """)
    }

    /// The same for `Slice` and `SliceStable`, which are the other family
    /// of the same text.
    @Test func theCallsOfALessFunctionAreGos() throws {
        #expect(
            try runGoMain(
                """
                for _, n := range []int{0, 1, 2, 13, 50, 100} {
                    for shape := 0; shape < 9; shape++ {
                        base := input(n, shape)
                        xs := clone(base)
                        calls, sum := 0, 0
                        sort.Slice(xs, func(i, j int) bool {
                            calls++
                            sum = (sum*1000003 + i*31 + j + 7) & 0xfffffffffffff
                            return xs[i].key < xs[j].key
                        })
                        ys := clone(base)
                        stableCalls, stableSum := 0, 0
                        sort.SliceStable(ys, func(i, j int) bool {
                            stableCalls++
                            stableSum = (stableSum*1000003 + i*31 + j + 7) & 0xfffffffffffff
                            return ys[i].key < ys[j].key
                        })
                        zs := clone(base)
                        badCalls, badSum := 0, 0
                        sort.Slice(zs, func(i, j int) bool {
                            badCalls++
                            badSum = (badSum*1000003 + i*31 + j + 7) & 0xfffffffffffff
                            return (zs[i].key*31+zs[j].tag)%3 == 0
                        })
                        fmt.Println(n, shape, calls, sum, digest(xs), stableCalls, stableSum, digest(ys), badCalls, badSum, digest(zs))
                    }
                }
                """,
                imports: ["fmt", "sort"],
                declarations: """
                    type item struct{ key, tag int }

                    // recorder is a sort.Interface that sums up every call it gets.
                    type recorder struct {
                        items []item
                        calls int
                        sum   int
                        bad   bool
                    }

                    func (r *recorder) Len() int { return len(r.items) }

                    func (r *recorder) Less(i, j int) bool {
                        r.calls++
                        r.sum = (r.sum*1000003 + i*31 + j + 7) & 0xfffffffffffff
                        if r.bad {
                            return (r.items[i].key*31+r.items[j].tag)%3 == 0
                        }
                        return r.items[i].key < r.items[j].key
                    }

                    func (r *recorder) Swap(i, j int) {
                        r.calls++
                        r.sum = (r.sum*1000003 + i*17 + j + 3) & 0xfffffffffffff
                        r.items[i], r.items[j] = r.items[j], r.items[i]
                    }

                    var seed = 12345

                    func next(n int) int {
                        seed = (seed*1103515245 + 12345) & 0x7fffffff
                        return (seed >> 8) % n
                    }

                    // input is n items in one of nine arrangements, most with many equal keys.
                    func input(n, shape int) []item {
                        items := make([]item, n)
                        choices := []int{1, 2, 3, 5, 10, 100, 1000000}
                        distinct := choices[next(7)]
                        for i := 0; i < n; i++ {
                            key := 0
                            switch shape {
                            case 0:
                                key = next(distinct)
                            case 1:
                                key = i
                            case 2:
                                key = n - i
                            case 3:
                                key = i % (distinct + 1)
                            case 4:
                                key = 7
                            case 5:
                                if i < n/2 {
                                    key = i
                                } else {
                                    key = n - i
                                }
                            case 6:
                                key = i
                                if next(50) == 0 {
                                    key = next(n + 1)
                                }
                            case 7:
                                key = (n - i) / (1 + next(3))
                            case 8:
                                key = (i / 7) % 5
                            }
                            items[i] = item{key, i}
                        }
                        return items
                    }

                    func clone(items []item) []item {
                        out := make([]item, len(items))
                        copy(out, items)
                        return out
                    }

                    func digest(items []item) int {
                        sum := 0
                        for _, it := range items {
                            sum = (sum*1000003 + it.key*131 + it.tag) & 0xfffffffffffff
                        }
                        return sum
                    }
                    """,
                machine: GoVirtualMachine(maximumInstructions: 12_000_000))
                == """
                0 0 0 0 0 0 0 0 0 0 0
                0 1 0 0 0 0 0 0 0 0 0
                0 2 0 0 0 0 0 0 0 0 0
                0 3 0 0 0 0 0 0 0 0 0
                0 4 0 0 0 0 0 0 0 0 0
                0 5 0 0 0 0 0 0 0 0 0
                0 6 0 0 0 0 0 0 0 0 0
                0 7 0 0 0 0 0 0 0 0 0
                0 8 0 0 0 0 0 0 0 0 0
                1 0 0 0 1048 0 0 1048 0 0 1048
                1 1 0 0 0 0 0 0 0 0 0
                1 2 0 0 131 0 0 131 0 0 131
                1 3 0 0 0 0 0 0 0 0 0
                1 4 0 0 917 0 0 917 0 0 917
                1 5 0 0 131 0 0 131 0 0 131
                1 6 0 0 0 0 0 0 0 0 0
                1 7 0 0 131 0 0 131 0 0 131
                1 8 0 0 0 0 0 0 0 0 0
                2 0 1 38 1 1 38 1 1 38 1000003
                2 1 1 38 132 1 38 132 1 38 132
                2 2 1 38 132000658 1 38 132000658 1 38 262000918
                2 3 1 38 132 1 38 132 1 38 132
                2 4 1 38 917003669 1 38 917003669 1 38 917003669
                2 5 1 38 132 1 38 132 1 38 132
                2 6 1 38 132 1 38 132 1 38 132
                2 7 1 38 1000265 1 38 1000265 1 38 1000265
                2 8 1 38 1 1 38 1 1 38 1000003
                13 0 33 3662055104894216 1537811041379236 46 1857816309421960 1958155215550148 30 515628681864357 566879374777314
                13 1 15 4417784425609060 4337228649371832 12 1480620276499088 4337228649371832 37 1089173031228581 1258503779273096
                13 2 33 103138901488979 3765510129220227 78 2177764173226984 3765510129220227 34 749554060445112 24853087599187
                13 3 15 4417784425609060 4337228649371832 12 1480620276499088 4337228649371832 37 1089173031228581 1258503779273096
                13 4 15 4417784425609060 2003140768258187 12 1480620276499088 2003140768258187 52 3110070151725932 2709917630343295
                13 5 34 3579426329208524 995300084495361 43 2920415697166350 691359700587937 40 1640046992525450 4446999652823951
                13 6 15 4417784425609060 4337228649371832 12 1480620276499088 4337228649371832 37 1089173031228581 1258503779273096
                13 7 55 2199218008608733 1981571452675503 71 3193776812062302 1772688707925597 32 2682882884677686 4227126143220373
                13 8 15 4417784425609060 4224328845917938 12 1480620276499088 4224328845917938 37 3913671861756041 1605691609601368
                50 0 246 3583128722187203 3726390693204698 302 4272611629763708 1820382916163244 228 3639071789493806 1006329531434538
                50 1 61 367285576575689 2253480775856100 61 611594592316570 2253480775856100 270 3929451948983715 3364446875442492
                50 2 61 4245274400666542 1089307939499906 444 3939807392424077 1089307939499906 61 367285576575689 1843998016317158
                50 3 61 367285576575689 2253480775856100 61 611594592316570 2253480775856100 270 3929451948983715 3364446875442492
                50 4 61 367285576575689 2461073861805005 61 611594592316570 2461073861805005 250 2376420994025329 835834271236595
                50 5 251 790143495977353 3731721380693820 298 3642030756091843 2635440931402668 172 1747204294901853 328368186334860
                50 6 69 4240225600260233 3226502256116571 67 1522912920688146 3226502256116571 253 2897691615116188 3354328039711363
                50 7 270 2925962568099837 3466320990564381 393 3995626085099840 1876651053691579 125 3908541067783382 540263101560161
                50 8 173 3128752052355303 1647367596522110 163 2536103657197356 4325391315647300 169 452722634096303 3527621154797474
                100 0 336 3518238028490838 2352572322675254 404 3738773272097008 3177983698087992 828 505231288405080 2770173737704910
                100 1 111 1537843005967510 2248074334583816 122 3864843332562968 2248074334583816 647 189810943002485 2335351033728632
                100 2 111 4064890766148134 3934809832470516 985 1852763193951644 3934809832470516 295 1245784727163475 1748105030671476
                100 3 111 1537843005967510 2248074334583816 122 3864843332562968 2248074334583816 647 189810943002485 2335351033728632
                100 4 111 1537843005967510 1907794305578314 122 3864843332562968 1907794305578314 581 82345484853113 554336229122234
                100 5 630 3649067048029077 1012213556292322 672 1981978229148417 2871592026434990 538 1258490632410350 1772500272005910
                100 6 111 1537843005967510 2248074334583816 122 3864843332562968 2248074334583816 647 189810943002485 2335351033728632
                100 7 589 1100406332719723 2172459074611228 825 764435831532119 650172820040458 429 2099789900868901 4153168385908750
                100 8 394 3075238869757797 4259489413271528 411 3784663511345468 2052649611486232 539 1444911669647005 4356551148035258

                """)
    }

    /// `sort.Slice` takes an `any`, so what it is given is known when it
    /// runs.
    @Test func whatIsNoSlicePanicsAsGosReflectDoes() throws {
        #expect(
            try runGoMain(
                """
                try("int", func() { sort.Slice(5, func(i, j int) bool { return false }) })
                try("string", func() { sort.Slice("abc", func(i, j int) bool { return false }) })
                try("nil", func() { sort.Slice(nil, func(i, j int) bool { return false }) })
                try("array", func() { sort.Slice([3]int{3, 2, 1}, func(i, j int) bool { return false }) })
                try("map", func() { sort.SliceStable(map[string]int{}, func(i, j int) bool { return false }) })
                try("pointer", func() { x := []int{1}; sort.SliceStable(&x, func(i, j int) bool { return false }) })
                try("is sorted", func() { sort.SliceIsSorted(5, func(i, j int) bool { return false }) })
                try("is sorted, nil", func() { sort.SliceIsSorted(nil, func(i, j int) bool { return false }) })
                try("nil slice", func() { var xs []int; sort.Slice(xs, func(i, j int) bool { return false }) })
                """,
                imports: ["fmt", "sort"],
                declarations: """
                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, recover()) }()
                        f()
                    }
                    """)
                == """
                int reflect: call of Swapper on int Value
                string reflect: call of Swapper on string Value
                nil reflect: call of Swapper on zero Value
                array reflect: call of Swapper on array Value
                map reflect: call of Swapper on map Value
                pointer reflect: call of Swapper on ptr Value
                is sorted reflect: call of reflect.Value.Len on int Value
                is sorted, nil reflect: call of reflect.Value.Len on zero Value
                nil slice <nil>

                """)
    }

    /// The sort runs as code of the program: a panic in `less` passes through
    /// it to whoever recovers, and a `less` that waits lets other goroutines
    /// run.
    @Test func aCallbackPanicsAndWaitsLikeAnyOtherCode() throws {
        #expect(
            try runGoMain(
                """
                try("less panics", func() {
                    xs := []int{3, 2, 1}
                    sort.Slice(xs, func(i, j int) bool { panic("in less") })
                })
                try("less out of range", func() {
                    xs := []int{3, 2, 1}
                    ys := []int{}
                    sort.Slice(xs, func(i, j int) bool { return ys[i] < ys[j] })
                })
                try("nil less", func() { sort.Slice([]int{3, 2, 1}, nil) })
                try("nil interface", func() {
                    var data sort.Interface
                    sort.Sort(data)
                })
                asked := make(chan int)
                answers := make(chan bool)
                go func() {
                    for i := range asked {
                        answers <- i < 2
                    }
                }()
                xs := []int{3, 0, 2, 1}
                sort.Slice(xs, func(i, j int) bool {
                    asked <- xs[i] - xs[j] + 2
                    return <-answers
                })
                close(asked)
                fmt.Println(xs)
                """,
                imports: ["fmt", "sort"],
                declarations: """
                    func try(name string, f func()) {
                        defer func() { fmt.Println(name, recover()) }()
                        f()
                    }
                    """)
                == """
                less panics in less
                less out of range runtime error: index out of range [1] with length 0
                nil less runtime error: invalid memory address or nil pointer dereference
                nil interface runtime error: invalid memory address or nil pointer dereference
                [0 1 2 3]

                """)
    }

    /// A function of the library that is Go text is a function of the
    /// program, and a value like one.
    @Test func theFunctionsAreValues() throws {
        #expect(
            try runGoMain(
                #"""
                xs := []int{3, 1, 2}
                slice := sort.Slice
                slice(xs, func(i, j int) bool { return xs[i] > xs[j] })
                sorts := []func(sort.Interface){sort.Sort, sort.Stable}
                for _, each := range sorts {
                    each(sort.Reverse(sort.IntSlice(xs)))
                }
                search := sort.SearchInts
                fmt.Println(xs, by(sort.Slice, []string{"b", "a"}), search([]int{1, 2, 3}, 3))
                fmt.Printf("%T\n%T\n%T\n%T\n%T\n", slice, sort.Sort, sort.Search, sort.Reverse, sort.SearchStrings)
                fmt.Printf("%T\n%T\n", sort.IntSlice.Len, sort.IntSlice{}.Swap)
                defer sort.Slice(xs, func(i, j int) bool { fmt.Println("deferred", i, j); return false })
                """#,
                imports: ["fmt", "sort"],
                declarations: """
                    func by(sorter func(interface{}, func(i, j int) bool), names []string) []string {
                        sorter(names, func(i, j int) bool { return names[i] < names[j] })
                        return names
                    }
                    """)
                == """
                [3 2 1] [a b] 2
                func(interface {}, func(int, int) bool)
                func(sort.Interface)
                func(int, func(int) bool) int
                func(sort.Interface) sort.Interface
                func([]string, string) int
                func(sort.IntSlice) int
                func(int, int)
                deferred 1 0
                deferred 2 1

                """)
    }

    /// An import under another name, a dot import, a variable that hides the
    /// package, types declared in a function, aliases, and package-level
    /// variables that are initialized by a sort.
    @Test func everyPassSeesTheLibrary() throws {
        #expect(
            try runGoMain(
                """
                sort := []int{3, 1, 2}
                srt.Slice(sort, func(i, j int) bool { return sort[i] < sort[j] })
                f.Println(sort, srt.SearchInts(sort, 2), sorted, at)
                type entry struct {
                    name  string
                    score int
                }
                type board []entry
                b := board{entry{"a", 3}, entry{"b", 9}, entry{"c", 1}, entry{"d", 9}}
                srt.SliceStable(b, func(i, j int) bool { return b[i].score > b[j].score })
                var is ints = []int{4, 2, 9}
                is.Sort()
                var byScore lessFunc = func(i, j int) bool { return b[i].score < b[j].score }
                f.Println(b, is, is.Search(4), srt.SliceIsSorted(b, byScore))
                by(sort, func(i, j int) bool { return sort[i] > sort[j] })
                f.Println(sort)
                """,
                declarations: """
                    import (
                        f "fmt"
                        srt "sort"
                    )

                    type ints = srt.IntSlice
                    type lessFunc = func(i, j int) bool

                    var (
                        sorted = sortedCopy([]int{5, 3, 9})
                        at     = srt.SearchInts(sorted, 5)
                        by     = srt.Slice
                    )

                    func sortedCopy(xs []int) []int {
                        out := append([]int{}, xs...)
                        srt.Slice(out, func(i, j int) bool { return out[i] < out[j] })
                        return out
                    }
                    """)
                == "[1 2 3] 1 [3 5 9] 1\n[{b 9} {d 9} {a 3} {c 1}] [2 4 9] 1 false\n[3 2 1]\n")
        #expect(
            try runGoMain(
                """
                xs := []int{3, 1, 2}
                Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })
                Println(xs, SearchInts(xs, 2))
                Ints(xs)
                Sort(Reverse(IntSlice(xs)))
                var s StringSlice = []string{"b", "a"}
                s.Sort()
                Println(xs, s)
                """,
                declarations: """
                    import (
                        . "fmt"
                        . "sort"
                    )
                    """)
                == "[1 2 3] 1\n[3 2 1] [a b]\n")
        #expect(
            try runGoMain(
                """
                xs := []int{3, 1, 2}
                sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })
                fmt.Println(xs)
                {
                    sort := &sorter{}
                    ys := []int{3, 1, 2}
                    sort.Slice(ys, func(i, j int) bool { return ys[i] < ys[j] })
                    fmt.Println(ys, sort.calls)
                }
                func(sort *sorter) {
                    ys := []int{3, 1, 2}
                    sort.Slice(ys, func(i, j int) bool { return ys[i] < ys[j] })
                    fmt.Println(ys, sort.calls)
                }(&sorter{})
                sort.Sort(sort.Reverse(sort.IntSlice(xs)))
                fmt.Println(xs)
                """,
                imports: ["fmt", "sort"],
                declarations: """
                    type sorter struct{ calls int }

                    func (s *sorter) Slice(x []int, less func(i, j int) bool) { s.calls++ }
                    """)
                == "[1 2 3]\n[3 1 2] 1\n[3 1 2] 1\n[3 2 1]\n")
    }

    /// The functions are checked like functions of the program. Go names the
    /// operand too, and says which method a type lacks.
    @Test func aWrongArgumentIsRefused() {
        #expect(
            goMainDiagnostic(
                """
                xs := []int{2, 1}
                sort.Slice(xs, 1)
                fmt.Println(xs)
                """,
                imports: ["fmt", "sort"])
                == "cannot use int as func(int, int) bool value in argument to sort.Slice")
        #expect(
            goMainDiagnostic(
                """
                xs := []int{2, 1}
                sort.Slice(xs, func(i, j int) int { return 0 })
                fmt.Println(xs)
                """,
                imports: ["fmt", "sort"])
                == "cannot use func(int, int) int as func(int, int) bool value in argument to sort.Slice")
        #expect(
            goMainDiagnostic(
                """
                xs := []int{2, 1}
                sort.Slice(xs)
                fmt.Println(xs)
                """,
                imports: ["fmt", "sort"])
                == "not enough arguments in call to sort.Slice")
        #expect(
            goMainDiagnostic(
                """
                xs := []int{2, 1}
                sort.Sort(xs)
                fmt.Println(xs)
                """,
                imports: ["fmt", "sort"])
                == "cannot use []int as sort.Interface value in argument to sort.Sort")
        #expect(
            goMainDiagnostic(
                """
                var s sort.IntSlice = []string{"a"}
                fmt.Println(s)
                """,
                imports: ["fmt", "sort"])
                == "cannot use []string as sort.IntSlice value")
        #expect(
            firstError("fmt.Println(sort.NoSuch(1))", imports: ["fmt", "sort"])
                == "6:18: undefined: sort.NoSuch")
        #expect(
            firstError("fmt.Println(sort.insertionSort)", imports: ["fmt", "sort"])
                == "6:18: undefined: sort.insertionSort")
    }
}
