enum SampleCode {
    static let lesson = """
        package main

        import (
        	"errors"
        	"fmt"
        	"strings"
        )

        // Order is one line on a bakery receipt.
        type Order struct {
        	Item     string
        	Quantity int
        }

        var errNoItem = errors.New("order has no item")

        // price checks an order and returns what it costs.
        func price(o Order) (float64, error) {
        	if strings.TrimSpace(o.Item) == "" {
        		return 0, errNoItem
        	}
        	cost := 2.5 * float64(o.Quantity)
        	return cost, nil
        }

        func main() {
        	orders := []Order{
        		{Item: "Rye loaf", Quantity: 2},
        		{Item: "", Quantity: 1},
        	}
        	total := 0.0
        	for i, o := range orders {
        		cost, err := price(o)
        		if err != nil {
        			fmt.Printf("order %d: %v\\n", i+1, err)
        			continue
        		}
        		total += cost
        	}
        	fmt.Printf("Total: $%.2f\\n", total)
        }

        """

    static let readmeSnippet = """
        func price(o Order) (float64, error) {
        	if o.Item == "" {
        		return 0, errNoItem
        	}
        	return 2.5 * float64(o.Quantity), nil
        }
        """

    /// About 5,000 lines of code, to check the editor stays smooth.
    static let large: String = {
        var lines = ["package main", "", "import \"fmt\"", ""]
        var number = 0
        while lines.count < 5_000 {
            number += 1
            lines += [
                "// handler\(number) totals the costs of batch \(number).",
                "func handler\(number)(costs []float64) (float64, error) {",
                "\ttotal := 0.0",
                "\tfor _, cost := range costs {",
                "\t\tif cost < 0 {",
                "\t\t\treturn 0, fmt.Errorf(\"batch \(number): negative cost %v\", cost)",
                "\t\t}",
                "\t\ttotal += cost * 1.\(number % 10)",
                "\t}",
                "\treturn total, nil",
                "}",
                "",
            ]
        }
        return lines.prefix(5_000).joined(separator: "\n") + "\n"
    }()
}
